private PLAIN_TEXT_TYPES = {
  "application/json",
  "application/javascript",
  "application/xml",
  "application/vnd.api+json",
  "application/vnd.oai.openapi",
}

private COMPRESS_ENCODING = {"gzip", "deflate"}

private def serialize_headers(headers : HTTP::Headers, builder : JSON::Builder)
  builder.object do
    headers.each do |key, value|
      builder.string key
      builder.string do |io|
        if value.is_a? Array(String)
          value.join(io, ",")
        else
          io << value
        end
      end
    end
  end
end

private def serialize_multi_value_headers(headers : HTTP::Headers, builder : JSON::Builder)
  builder.object do
    headers.each do |key, value|
      builder.string key
      if value.is_a? Array(String)
        value.to_json builder
      else
        builder.array { builder.string value }
      end
    end
  end
end

module Crowbar::BufferedAdapter
  abstract def parse_http_request(event : IO) : HTTP::Request
  abstract def serialize_http_response(response : Crowbar::HttpServerResponse) : String
end

module Crowbar::StreamingAdapter(T)
  abstract def parse_http_request(event : IO) : HTTP::Request
end

# Crystal >= 1.22 no longer sets Content-Length when a request is given a body.
private def build_request(method : String, resource : String, headers : HTTP::Headers, body : String?, is_base64_encoded : Bool?) : HTTP::Request
  decoded_body = body.try { |encoded| is_base64_encoded ? Base64.decode(encoded) : encoded }
  request = HTTP::Request.new(method: method, resource: resource, headers: headers, body: decoded_body)
  request.content_length = decoded_body.bytesize.to_i64 if decoded_body
  request
end

private def parse_proxy_request(event : IO, encoded_query : Bool) : HTTP::Request
  headers = HTTP::Headers.new
  path = method = is_base64_encoded = body = nil
  uri_params = URI::Params.new

  pull = JSON::PullParser.new(event)
  pull.read_object do |key|
    case key
    when "headers"
      pull.read_object { |key| headers[key] = pull.read_string }
    when "multiValueHeaders"
      pull.read_object { |key| headers[key] = Array(String).new(pull) }
    when "httpMethod"
      method = pull.read_string
    when "path"
      path = pull.read_string
    when "queryStringParameters"
      pull.read_null_or do
        pull.read_object do |name|
          value = pull.read_string
          if encoded_query
            uri_params[URI.decode_www_form(name)] = URI.decode_www_form(value)
          else
            uri_params[name] = value
          end
        end
      end
    when "multiValueQueryStringParameters"
      pull.read_null_or do
        pull.read_object do |name|
          values = Array(String).new(pull)
          if encoded_query
            uri_params[URI.decode_www_form(name)] = values.map { |value| URI.decode_www_form(value) }
          else
            uri_params[name] = values
          end
        end
      end
    when "body"
      body = pull.read_string_or_null
    when "isBase64Encoded"
      is_base64_encoded = pull.read_bool
    else pull.skip
    end
  end

  build_request method.not_nil!, "#{path}?#{uri_params}", headers, body, is_base64_encoded
end

private def serialize_proxy_response(response : Crowbar::HttpServerResponse, multi_value_headers : Bool) : String
  is_base64_encoded = false
  body_io = response.io.as(IO::Memory)
  body = nil
  response.cookies.add_response_headers(response.headers) if response.has_cookies?

  if (content_type = response.headers["Content-Type"]?).nil?
    body = body_io.to_s
  else
    is_plain_text = content_type.starts_with?("text/") || content_type.in?(PLAIN_TEXT_TYPES)
    is_compressed = response.headers["Content-Encoding"]?.try(&.in?(COMPRESS_ENCODING)) || false

    if is_plain_text && !is_compressed
      body = body_io.to_s
    else
      is_base64_encoded = true
      body = Base64.strict_encode(body_io.to_slice)
    end
  end

  JSON.build do |json|
    json.object do
      json.field "statusCode", response.status_code
      if multi_value_headers
        json.field "multiValueHeaders" { serialize_multi_value_headers response.headers, json }
      else
        json.field "headers" { serialize_headers response.headers, json }
      end
      json.field "body", body || ""
      json.field "isBase64Encoded", is_base64_encoded
    end
  end
end

module Crowbar::APIGatewayV1Adapter
  extend BufferedAdapter

  class_property? multi_value_headers = false

  def self.parse_http_request(event : IO) : HTTP::Request
    parse_proxy_request event, encoded_query: false
  end

  def self.serialize_http_response(response : HttpServerResponse) : String
    serialize_proxy_response response, multi_value_headers?
  end
end

module Crowbar::ApplicationLoadBalancerAdapter
  extend BufferedAdapter

  class_property? multi_value_headers = false

  def self.parse_http_request(event : IO) : HTTP::Request
    parse_proxy_request event, encoded_query: true
  end

  def self.serialize_http_response(response : HttpServerResponse) : String
    serialize_proxy_response response, multi_value_headers?
  end
end

module Crowbar::APIGatewayV2Adapter
  extend BufferedAdapter

  def self.parse_http_request(event : IO) : HTTP::Request
    headers = HTTP::Headers.new
    raw_path = raw_query_string = method = is_base64_encoded = body = nil

    pull = JSON::PullParser.new(event)
    pull.read_object do |key|
      case key
      when "headers"
        pull.read_object { |key| headers.add(key, pull.read_string) }
      when "requestContext"
        pull.on_key!("http", &.on_key("method") { method = pull.read_string })
      when "rawPath"
        raw_path = pull.read_string
      when "rawQueryString"
        raw_query_string = pull.read_string
      when "body"
        body = pull.read_string
      when "isBase64Encoded"
        is_base64_encoded = pull.read_bool
      else pull.skip
      end
    end

    build_request method.not_nil!, "#{raw_path}?#{raw_query_string}", headers, body, is_base64_encoded
  end

  def self.serialize_http_response(response : HttpServerResponse) : String
    is_base64_encoded = false
    body_io = response.io.as(IO::Memory)
    body = nil

    if (content_type = response.headers["Content-Type"]?).nil?
      body = body_io.to_s
    else
      is_plain_text = content_type.starts_with?("text/") || content_type.in?(PLAIN_TEXT_TYPES)
      is_compressed = response.headers["Content-Encoding"]?.try(&.in?(COMPRESS_ENCODING)) || false

      if is_plain_text && !is_compressed
        body = body_io.to_s
      else
        is_base64_encoded = true
        body = Base64.strict_encode(body_io.to_slice)
      end
    end

    JSON.build do |json|
      json.object do
        json.field "statusCode", response.status_code
        json.field "headers" { serialize_headers response.headers, json }
        json.field "cookies" do
          json.array { response.cookies.each { |cookie| json.string { |io| cookie.to_set_cookie_header io } } }
        end if response.has_cookies?
        json.field "body", body || ""
        json.field "isBase64Encoded", is_base64_encoded
      end
    end
  end
end

alias Crowbar::LambdaURLAdapter = Crowbar::APIGatewayV2Adapter

module Crowbar::LambdaURLStreamingAdapter
  extend Crowbar::StreamingAdapter(HttpResponseIO)

  def self.parse_http_request(event : IO) : HTTP::Request
    Crowbar::LambdaURLAdapter.parse_http_request event
  end
end
