require "./spec_helper"

describe Crowbar do
  describe "handle_events buffered overload" do
    it "deserializes the events according to the event type" do
      sent_event = %({"result": 10})

      LambdaTestServer.test_invocation(sent_event, String) do |received_event, _|
        received_event.should eq sent_event
      end

      LambdaTestServer.test_invocation(sent_event, Bytes) do |received_event, _|
        received_event.should eq sent_event.to_slice
      end

      LambdaTestServer.test_invocation(sent_event, IO) do |received_event, _|
        received_event.gets_to_end.should eq sent_event
      end

      LambdaTestServer.test_invocation(sent_event, NamedTuple(result: Int32)) do |received_event, _|
        received_event.should eq({result: 10})
      end
    end

    it "properly generates the context object" do
      LambdaTestServer.test_invocation("", String) do |_, context|
        UUID.parse?(context.aws_request_id).should_not be_nil
        context.client_context.should be_nil
        context.deadline.should eq Time.utc(2023, 11, 14, 22, 13, 20)
        context.function_name.should eq "function_name"
        context.function_version.should eq "function_version"
        context.identity.should be_nil
        context.invoked_function_arn.should eq "arn:aws:lambda:region:account-id:function:test-function"
        context.log_group_name.should eq "log_group_name"
        context.log_stream_name.should eq "log_stream_name"
        context.memory_limit_in_mb.should eq 512
      end
    end

    it "serializes the handler responses according to their types" do
      handler = ->(event : String, context : Crowbar::Context) { "String Response" }
      LambdaTestServer.test_invocation("", handler) do |context|
        context.request.body.not_nil!.gets_to_end.should eq "String Response"
      end

      handler = ->(event : Bytes, context : Crowbar::Context) { Bytes[0, 0, 0, 0] }
      LambdaTestServer.test_invocation("", handler) do |context|
        context.request.body.not_nil!.getb_to_end.should eq Bytes[0, 0, 0, 0]
      end

      handler = ->(event : Bytes, context : Crowbar::Context) { IO::Memory.new "{}" }
      LambdaTestServer.test_invocation("", handler) do |context|
        context.request.body.not_nil!.gets_to_end.should eq "{}"
      end

      handler = ->(event : Bytes, context : Crowbar::Context) { {status_code: 200} }
      LambdaTestServer.test_invocation("", handler) do |context|
        context.request.body.not_nil!.gets_to_end.should eq %({"status_code":200})
      end
    end

    it "handles errors properly by posting to error endpoint" do
      event = %({"wrong_key": 10})

      Crowbar.capture_log_output do
        handler = ->(event : String, context : Crowbar::Context) { raise "Error on handler" }
        LambdaTestServer.test_invocation(event, handler) do |context|
          context.request.path.should end_with "/error"
          error = LambdaTestServer::HandlerError.from_json(context.request.body.not_nil!)
          error.message.should eq "Error on handler"
          error.type.should eq "Exception"
          error.stack_trace.first.should match /spec\/crowbar_spec.cr:\d+:\d+ in '->'/
        end

        handler = ->(event : NamedTuple(value: Int32), context : Crowbar::Context) { event[:value] }
        LambdaTestServer.test_invocation(event, handler) do |context|
          context.request.path.should end_with "/error"
          error = LambdaTestServer::HandlerError.from_json(context.request.body.not_nil!)
          error.message.should eq "Missing json attribute: value at line 1, column 1"
          error.type.should eq "JSON::ParseException"
          error.stack_trace.first.should match /\/usr\/lib\/crystal\/json\/from_json.cr:\d+:\d+ in 'new'/
        end
      end
    end
  end

  describe "handle_events streaming overload" do
    it "deserializes the events according to the event type" do
      sent_event = %({"result": 10})

      LambdaTestServer.test_invocation(sent_event, String, Crowbar::ResponseIO) do |received_event, _, _|
        received_event.should eq sent_event
      end

      LambdaTestServer.test_invocation(sent_event, Bytes, Crowbar::ResponseIO) do |received_event, _, _|
        received_event.should eq sent_event.to_slice
      end

      LambdaTestServer.test_invocation(sent_event, IO, Crowbar::ResponseIO) do |received_event, _, _|
        received_event.gets_to_end.should eq sent_event
      end

      LambdaTestServer.test_invocation(sent_event, NamedTuple(result: Int32), Crowbar::ResponseIO) do |received_event, _, _|
        received_event.should eq({result: 10})
      end
    end

    it "properly generates the context object" do
      LambdaTestServer.test_invocation("", String, Crowbar::ResponseIO) do |_, context|
        UUID.parse?(context.aws_request_id).should_not be_nil
        context.client_context.should be_nil
        context.deadline.should eq Time.utc(2023, 11, 14, 22, 13, 20)
        context.function_name.should eq "function_name"
        context.function_version.should eq "function_version"
        context.identity.should be_nil
        context.invoked_function_arn.should eq "arn:aws:lambda:region:account-id:function:test-function"
        context.log_group_name.should eq "log_group_name"
        context.log_stream_name.should eq "log_stream_name"
        context.memory_limit_in_mb.should eq 512
      end
    end

    it "progressively streams the handler response" do
      handler = ->(event : String, context : Crowbar::Context, io : Crowbar::ResponseIO) do
        io << "First line of content"
        io.flush
        io << "Second line of content"
      end

      LambdaTestServer.test_invocation("", handler) do |context|
        context.request.headers.should eq HTTP::Headers{
          "Content-Type"                          => "application/octet-stream",
          "Host"                                  => "127.0.0.1:9876",
          "Lambda-Runtime-Function-Response-Mode" => "streaming",
          "Trailer"                               => "Lambda-Runtime-Function-Error-Type, Lambda-Runtime-Function-Error-Body",
          "Transfer-Encoding"                     => "chunked",
        }

        raw_body = context.request.body.as(HTTP::ChunkedContent).io
        raw_body.gets(chomp: false).should eq "15\r\n"
        raw_body.gets(chomp: false).should eq "First line of content\r\n"
        raw_body.gets(chomp: false).should eq "16\r\n"
        raw_body.gets(chomp: false).should eq "Second line of content\r\n"
        raw_body.gets(chomp: false).should eq "0\r\n"
        raw_body.gets(chomp: false).should eq "\r\n"
      end
    end

    it "handles errors before writes to the response io by posting to error endpoint" do
      event = %({"wrong_key": 10})

      Crowbar.capture_log_output do
        handler = ->(event : String, context : Crowbar::Context, io : Crowbar::ResponseIO) { raise "Error on handler" }
        LambdaTestServer.test_invocation(event, handler) do |context|
          context.request.path.should end_with "/error"
          error = LambdaTestServer::HandlerError.from_json(context.request.body.not_nil!)
          error.message.should eq "Error on handler"
          error.type.should eq "Exception"
          error.stack_trace.first.should match /spec\/crowbar_spec.cr:\d+:\d+ in '->'/
        end

        handler = ->(event : NamedTuple(value: Int32), context : Crowbar::Context, io : Crowbar::ResponseIO) { event[:value] }
        LambdaTestServer.test_invocation(event, handler) do |context|
          context.request.path.should end_with "/error"
          error = LambdaTestServer::HandlerError.from_json(context.request.body.not_nil!)
          error.message.should eq "Missing json attribute: value at line 1, column 1"
          error.type.should eq "JSON::ParseException"
          error.stack_trace.first.should match /\/usr\/lib\/crystal\/json\/from_json.cr:\d+:\d+ in 'new'/
        end
      end
    end

    it "handles errors after writes to the response io by sending trailer" do
      event = %({"wrong_key": 10})

      handler = ->(event : String, context : Crowbar::Context, io : Crowbar::ResponseIO) {
        io << "Initial write"
        io.flush
        raise "Error on handler"
      }

      Crowbar.capture_log_output do
        LambdaTestServer.test_invocation(event, handler) do |context|
          context.request.path.should end_with "/response"
          raw_body = context.request.body.as(HTTP::ChunkedContent).io
          raw_body.gets(chomp: false).should eq "d\r\n"
          raw_body.gets(chomp: false).should eq "Initial write\r\n"
          raw_body.gets(chomp: false).should eq "0\r\n"
          raw_body.gets(chomp: false).should eq "Lambda-Runtime-Function-Error-Type: Exception\r\n"
          raw_body.gets(chomp: false).should match /Lambda-Runtime-Function-Error-Body: .+\r\n/
          raw_body.gets(chomp: false).should eq "\r\n"
        end
      end
    end

    it "serializes http metadata for HttpResponseIO" do
      handler = ->(event : String, context : Crowbar::Context, io : Crowbar::HttpResponseIO) do
        cookies = HTTP::Cookies{"flavor" => "chocolate", "topper" => "cream"}
        cookies["topper"].expires = Time.utc(2025, 1, 1, 10, 10, 10)

        io.headers = HTTP::Headers{"Content-Type" => "application/json", "Target" => "Mars"}
        io.cookies = cookies

        io << %({"key":)
        io.flush
        io << %( "value"})
      end

      LambdaTestServer.test_invocation("", handler) do |context|
        context.request.headers.should eq HTTP::Headers{
          "Content-Type"                          => "application/vnd.awslambda.http-integration-response",
          "Host"                                  => "127.0.0.1:9876",
          "Lambda-Runtime-Function-Response-Mode" => "streaming",
          "Trailer"                               => "Lambda-Runtime-Function-Error-Type, Lambda-Runtime-Function-Error-Body",
          "Transfer-Encoding"                     => "chunked",
        }

        raw_body = context.request.body.as(HTTP::ChunkedContent).io
        raw_body.gets(chomp: false).should eq "ad\r\n"
        raw_body.gets(chomp: false).should eq %({"statusCode":200,"headers":{"Content-Type":"application/json","Target":"Mars"},"cookies":["flavor=chocolate","topper=cream; expires=Wed, 01 Jan 2025 10:10:10 GMT"]}\u0000\u0000\u0000\u0000\u0000\u0000\u0000\u0000\r\n)
        raw_body.gets(chomp: false).should eq "7\r\n"
        raw_body.gets(chomp: false).should eq %({"key":\r\n)
        raw_body.gets(chomp: false).should eq "9\r\n"
        raw_body.gets(chomp: false).should eq %( "value"}\r\n)
        raw_body.gets(chomp: false).should eq "0\r\n"
        raw_body.gets(chomp: false).should eq "\r\n"
      end
    end
  end
end
