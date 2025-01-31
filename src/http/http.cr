require "./server_response"
require "./adapters"

module Crowbar
  private alias Handler = HTTP::Handler | HTTP::Handler::HandlerProc

  protected def self.process_http_request(request : HTTP::Request, response : HttpServerResponse, handler : Handler)
    response.version = request.version
    context = HTTP::Server::Context.new(request, response)

    handler.call(context)
  rescue ex
    ex.inspect_with_backtrace log_output
    response.respond_with_status(:internal_server_error) unless response.closed? || response.wrote_headers?
  ensure
    response.flush
    response.output.close
  end

  def self.handle_events(with http_handler : Handler, using adapter : BufferedAdapter)
    handle_events(of_type: IO) do |event, context|
      request = adapter.parse_http_request event
      response = HttpServerResponse.new(IO::Memory.new)
      process_http_request request, response, http_handler
      adapter.serialize_http_response response
    end
  end

  def self.handle_events(with http_handler : Handler, using adapter : StreamingAdapter(T)) forall T
    handle_events(of_type: IO, writing_to: T) do |event, context, response_io|
      request = adapter.parse_http_request event
      response = HttpServerResponse.new(response_io)
      response_io.bound_response = response
      process_http_request request, response, http_handler
    end
  end

  def self.handle_events(with http_server : HTTP::Server, using adapter : BufferedAdapter)
    handle_events with: http_server.handler, using: adapter
  end

  def self.handle_events(with http_server : HTTP::Server, using adapter : StreamingAdapter(T)) forall T
    handle_events with: http_server.handler, using: adapter
  end
end
