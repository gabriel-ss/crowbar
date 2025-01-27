require "http/client"
require "json"
require "base64"
require "./context"
require "./http/cookie"

private macro handle_event(event_type, invocation, context, output_io = nil)
{% if event_type.resolve <= Bytes %}
  yield {{invocation}}.body_io.getb_to_end, {{context}} {% if output_io %},{{output_io}}{% end %}
{% elsif event_type.resolve <= String %}
  yield {{invocation}}.body_io.gets_to_end, {{context}} {% if output_io %},{{output_io}}{% end %}
{% elsif event_type.resolve <= IO %}
  yield {{invocation}}.body_io, {{context}} {% if output_io %},{{output_io}}{% end %}
{% else %}
  yield {{event_type}}.from_json({{invocation}}.body_io), {{context}} {% if output_io %},{{output_io}}{% end %}
{% end %}
end

private macro handle_invocation_body(event_type, invocation)
{% unless event_type.resolve <= Bytes || event_type.resolve <= String %}
  {{invocation}}.body_io.skip_to_end
{% end %}
end

module Crowbar
  private alias PrimitiveResponse = IO | Bytes | String | Nil

  private class_getter log_output : IO = STDERR

  def self.handle_events(with handler : Proc(T, Context, U)) forall T, U
    handle_events(of_type: T) { |event, context| handler.call(event, context) }
  end

  def self.handle_events(of_type event_type : T.class, &handler : T, Context -> U) forall T, U
    host, _, port = ENV["AWS_LAMBDA_RUNTIME_API"].rpartition(':')
    client = HTTP::Client.new(host, port)

    loop do
      client.get("/2018-06-01/runtime/invocation/next") do |invocation|
        raise "Failed to retrieve invocation data: #{invocation.body_io.gets_to_end}" if invocation.status_code != 200

        ENV["_X_AMZN_TRACE_ID"] = invocation.headers["Lambda-Runtime-Trace-Id"]?
        context = Context.new(invocation)

        begin
          {% begin %}
          begin
            result = handle_event({{T}}, invocation, context)
          ensure
            handle_invocation_body({{T}}, invocation)
          end
          {% end %}

          response = client.post(
            "/2018-06-01/runtime/invocation/#{context.aws_request_id}/response",
            body: {% if U.resolve <= PrimitiveResponse %} result {% else %} result.to_json {% end %}
          )
        rescue ex
          ex.inspect_with_backtrace log_output
          response = client.post(
            "/2018-06-01/runtime/invocation/#{context.aws_request_id}/error",
            body: {errorMessage: ex.message, errorType: ex.class.name, stackTrace: ex.backtrace}.to_json
          )
        end

        raise "Unexpected response when responding request '#{context.aws_request_id}': #{response.body}" if response.status_code != 202
      end
    end
  end

  def self.handle_events(with handler : Proc(T, Context, U, Nil)) forall T, U
    handle_events(of_type: T, writing_to: U) { |event, context, response_io| handler.call(event, context, response_io) }
  end

  def self.handle_events(of_type event_type : T.class, writing_to response_io_type : U.class, &handler : T, Context, U ->) forall T, U
    host, _, port = ENV["AWS_LAMBDA_RUNTIME_API"].rpartition(':')
    hostname = URI.unwrap_ipv6(host)
    client = HTTP::Client.new(host, port)

    loop do
      client.get("/2018-06-01/runtime/invocation/next") do |invocation|
        raise "Failed to retrieve invocation data: #{invocation.body_io.gets_to_end}" if invocation.status_code != 200

        ENV["_X_AMZN_TRACE_ID"] = invocation.headers["Lambda-Runtime-Trace-Id"]?
        context = Context.new(invocation)

        response_io = U.new(hostname, port, context.aws_request_id)

        {% begin %}
          begin
            handle_event({{T}}, invocation, context, response_io)
            response_io.write_termination
          rescue ex
            ex.inspect_with_backtrace log_output
            response_io.write_exception ex
          ensure
            handle_invocation_body({{T}}, invocation)
          end
        {% end %}

        response = response_io.read_response
        response_io.close_socket

        raise "Unexpected response when responding request '#{context.aws_request_id}': #{response.body}" if response.status_code != 202
      end
    end
  end

  private abstract class BaseResponseIO < IO
    include IO::Buffered

    private DEFAULT_STREAMING_HEADERS = <<-HEADERS
    Transfer-Encoding: chunked\r
    Trailer: Lambda-Runtime-Function-Error-Type, Lambda-Runtime-Function-Error-Body\r
    Lambda-Runtime-Function-Response-Mode: streaming\r

    HEADERS

    @content_type = "application/octet-stream"
    private property? writing_started = false

    protected def initialize(hostname : String, port : String, @aws_request_id : String)
      @socket = TCPSocket.new hostname, port
      @host_header = "Host: #{hostname}:#{port}\r\n"
      @closed = false
    end

    private def write_http_start_line(for response_type : String)
      @socket << "POST /2018-06-01/runtime/invocation/" << @aws_request_id << "/" << response_type << " HTTP/1.1\r\n"
    end

    private def write_exception_as_http_request(ex : Exception)
      body = {errorMessage: ex.message, errorType: ex.class.name, stackTrace: ex.backtrace}.to_json

      write_http_start_line for: "error"
      @socket << @host_header
      @socket << "Content-Type: application/json\r\n"
      @socket << "Content-Length: " << body.bytesize << "\r\n\r\n"

      @socket << body
    end

    private def write_exception_as_trailer(ex : Exception)
      @socket << "0\r\n"
      @socket << "Lambda-Runtime-Function-Error-Type: " << ex.class.name << "\r\n"
      @socket << "Lambda-Runtime-Function-Error-Body: "
      Base64.strict_encode(ex.inspect_with_backtrace, @socket)
      @socket << "\r\n\r\n"
    end

    protected def write_exception(ex : Exception)
      if writing_started?
        flush
        write_exception_as_trailer ex
      else
        write_exception_as_http_request ex
      end
    end

    private def write_prelude
      write_http_start_line for: "response"
      @socket << @host_header
      @writing_started = true
      @socket << DEFAULT_STREAMING_HEADERS << "Content-Type: " << @content_type << "\r\n\r\n"
    end

    protected def write_termination
      write_prelude unless writing_started?
      flush
      @socket << "0\r\n\r\n"
    end

    protected def read_response
      HTTP::Client::Response.from_io @socket
    end

    protected def close_socket
      @socket.close
    end

    def closed?
      @closed
    end

    def unbuffered_flush
      @socket.flush
    end

    def unbuffered_close
      @closed = true
    end

    def unbuffered_read(slice : Bytes)
      raise "Can't read from response buffer"
    end

    def unbuffered_write(slice : Bytes) : Nil
      write_prelude unless writing_started?

      slice.size.to_s(@socket, base: 16)
      @socket << "\r\n"
      @socket.write(slice)
      @socket << "\r\n"
      @socket.flush
    end

    def unbuffered_rewind
      @socket.rewind
    end
  end

  class ResponseIO < BaseResponseIO
    property content_type
  end

  class HttpResponseIO < BaseResponseIO
    include IO::Buffered

    property status_code : HTTP::Status = HTTP::Status::OK
    property headers : HTTP::Headers?
    property cookies : HTTP::Cookies?

    private PRELUDE_DELIMITER = Bytes.new(size: 8, value: 0)

    @content_type = "application/vnd.awslambda.http-integration-response"

    private def write_prelude
      super

      prelude = String.build(capacity: 128) do |str|
        status_code = self.status_code.code
        headers = self.headers
        cookies = self.cookies

        JSON.build(str) do |json|
          json.object do
            json.field "statusCode", status_code
            json.field "headers" { headers.to_json json } if headers
            json.field "cookies" do
              json.array { cookies.each { |cookie| json.string { |io| cookie.to_set_cookie_header io } } }
            end if cookies
          end
        end
        str.write PRELUDE_DELIMITER
      end.to_slice

      unbuffered_write prelude
    end
  end
end
