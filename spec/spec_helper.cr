require "spec"
require "uuid"
require "http/server"

ENV["AWS_LAMBDA_FUNCTION_NAME"] = "function_name"
ENV["AWS_LAMBDA_FUNCTION_VERSION"] = "function_version"
ENV["AWS_LAMBDA_FUNCTION_MEMORY_SIZE"] = "512"
ENV["AWS_LAMBDA_LOG_GROUP_NAME"] = "log_group_name"
ENV["AWS_LAMBDA_LOG_STREAM_NAME"] = "log_stream_name"

require "../src/crowbar"
require "../src/http"

# Crystal's HTTP server is too lenient with malformed requests, so chunked content
# tests are performed on the underlying TCP socket.
class HTTP::ChunkedContent
  def io
    @io
  end
end

module Crowbar
  class_getter captured_logs = IO::Memory.new

  def self.capture_log_output(&)
    log_output = @@log_output
    self.captured_logs.clear
    @@log_output = self.captured_logs
    yield
  ensure
    @@log_output = log_output.not_nil!
  end
end

class LambdaTestServer
  class HandlerError
    include JSON::Serializable

    @[JSON::Field(key: "errorMessage")]
    getter message : String

    @[JSON::Field(key: "errorType")]
    getter type : String

    @[JSON::Field(key: "stackTrace")]
    getter stack_trace : Array(String)
  end

  PORT = 9876

  property expectation_error : Exception? = nil

  def initialize(@event_body : String, &@response_expectation : HTTP::Server::Context ->)
    @server = HTTP::Server.new do |context|
      case {context.request.path, context.request.method}
      when {"/2018-06-01/runtime/invocation/next", "GET"}                      then handle_invocation_next(context)
      when {/^\/2018-06-01\/runtime\/invocation\/([^\/]+)\/([^\/]+)$/, "POST"} then handle_invocation_response(context, $1, $2)
      else                                                                          raise "Invalid request: #{context.request.method} #{context.request.path}"
      end
    end
    @server.bind_tcp("0.0.0.0", PORT)
  end

  def handle_invocation_next(context)
    @last_invocation_id = request_id = UUID.v4.to_s

    context.response.headers.merge! HTTP::Headers{
      "Lambda-Runtime-Aws-Request-Id"       => request_id,
      "Lambda-Runtime-Invoked-Function-Arn" => "arn:aws:lambda:region:account-id:function:test-function",
      "Lambda-Runtime-Deadline-Ms"          => "1700000000000",
      "Lambda-Runtime-Cognito-Identity"     => "null",
      "Lambda-Runtime-Client-Context"       => "null",
      "Lambda-Runtime-Trace-Id"             => "trace-id",
    }
    context.response.content_type = "application/json"
    context.response.status_code = 200
    context.response << @event_body
  end

  def handle_invocation_response(context, invocation_id, response_type)
    invocation_id.should eq(@last_invocation_id)
    context.response.content_type = "application/json"

    # Execute the handler 2 times to ensure runtime handles multiple invocations
    # and respond with an unexpected 200 to break out of the runtime loop
    context.response.status_code = @last_invocation_id.nil? ? 202 : 200
    context.response << "Test Concluded" unless @last_invocation_id.nil?

    begin
      @response_expectation.call(context)
    rescue ex
      @expectation_error = ex
    end
  end

  delegate listen, close, to: @server

  private def self.test_invocation(test_server : self, &)
    ENV["AWS_LAMBDA_RUNTIME_API"] = "127.0.0.1:#{PORT}"
    spawn { test_server.listen }

    yield
  rescue ex
    test_server.not_nil!.close
    raise ex unless ex.message.try &.matches? /Unexpected response when responding request '[0-9a-f\-]*': Test Concluded/
  ensure
    test_server.not_nil!.expectation_error.try { |error| raise error }
  end

  def self.test_invocation(
    event_body : String,
    test_handler : Proc(T, Crowbar::Context, U) | Proc(T, Crowbar::Context, U, Nil),
    &response_expectation : HTTP::Server::Context ->
  ) forall T, U
    test_server = self.new(event_body) { |context| response_expectation.call context }
    self.test_invocation(test_server) { Crowbar.handle_events with: test_handler }
  end

  def self.test_invocation(
    event_body : String,
    event_type : T.class,
    &test_handler : T, Crowbar::Context -> U
  ) forall T, U
    self.test_invocation(event_body, test_handler) do |context|
      if context.request.path.ends_with? "/error"
        raise HandlerError.from_json(context.request.body.not_nil!).message
      end
    end
  end

  def self.test_invocation(
    event_body : String,
    event_type : T.class,
    response_io_type : U.class,
    &test_handler : T, Crowbar::Context, U ->
  ) forall T, U
    self.test_invocation(event_body, test_handler) do |context|
      if context.request.path.ends_with? "/error"
        raise HandlerError.from_json(context.request.body.not_nil!).message
      end
    end
  end

  def self.test_adapter(
    event_body : String,
    handler : HTTP::Handler | HTTP::Handler::HandlerProc,
    adapter : Crowbar::BufferedAdapter | Crowbar::StreamingAdapter,
    &response_expectation : HTTP::Server::Context ->
  ) forall T, U
    test_server = self.new(event_body) do |context|
      current = handler
      while (current)
        current.last_error.try { |e| raise e } if current.responds_to? :last_error
        current = current.responds_to? :next ? current.next : nil
      end
      response_expectation.call context
    end

    self.test_invocation(test_server) { Crowbar.handle_events with: handler, using: adapter }
  end

  class ErrorHandler
    include HTTP::Handler

    property last_error : Exception?

    def initialize(&@handler : HTTP::Server::Context -> Nil); end

    def call(context) : Nil
      @last_error = nil
      @handler.call(context)
    rescue ex : Exception
      @last_error = ex
    end
  end
end
