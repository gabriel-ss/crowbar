require "http/server"

class Crowbar::HttpServerResponse < HTTP::Server::Response
  private ORIGINAL_OUTPUT = Output.new(IO::Memory.new(0))
  @original_output = ORIGINAL_OUTPUT

  getter io : IO

  protected setter wrote_headers

  def initialize(@io : IO, @version = "HTTP/1.1")
    @headers = HTTP::Headers.new
    @status = :ok
    @wrote_headers = false
    @output = @io
  end

  def reset
    @headers.clear
    @cookies = nil
    @status = :ok
    @status_message = nil
    @wrote_headers = false
    @output = @io
  end

  def has_cookies?
    !@cookies.nil?
  end

  def write(slice : Bytes) : Nil
    return if slice.empty?

    @output.write(slice)
  end

  def upgrade(&block : IO ->) : Nil
    raise "Can't upgrade connection inside a lambda."
  end

  def flush : Nil
    @output.flush
  end

  def close : Nil
    return if closed?

    @output.close
  end

  def closed? : Bool
    @output.closed?
  end

  def wrote_headers?
    @wrote_headers
  end
end

class HTTP::Server
  def handler
    @processor.handler
  end

  class RequestProcessor
    getter handler
  end
end
