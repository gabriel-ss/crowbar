require "./spec_helper"

API_GATEWAY_V1_REQUEST = <<-JSON
{
  "path": "/resource/path",
  "httpMethod": "GET",
  "headers": {
    "header1": "value1",
    "header2": "value2",
    "Accept-Encoding": "deflate"
  },
  "multiValueHeaders": {
    "header1": ["value1"],
    "header2": ["value1", "value2"],
    "Accept-Encoding": ["deflate"]
  },
  "queryStringParameters": {
    "parameter1": "value1",
    "parameter2": "value"
  },
  "multiValueQueryStringParameters": {
    "parameter1": ["value1", "value2"],
    "parameter2": ["value"]
  },
  "body": "Payload",
  "isBase64Encoded": false
}
JSON

API_GATEWAY_V1_BASE64_REQUEST = <<-JSON
{
  "path": "/resource/path",
  "httpMethod": "GET",
  "headers": {
    "header1": "value1",
    "header2": "value2",
    "Accept-Encoding": "deflate"
  },
  "multiValueHeaders": {
    "header1": ["value1"],
    "header2": ["value1", "value2"],
    "Accept-Encoding": ["deflate"]
  },
  "queryStringParameters": {
    "parameter1": "value1",
    "parameter2": "value"
  },
  "multiValueQueryStringParameters": {
    "parameter1": ["value1", "value2"],
    "parameter2": ["value"]
  },
  "body": "UGF5bG9hZA==",
  "isBase64Encoded": true
}
JSON

API_GATEWAY_V2_REQUEST = <<-JSON
{
  "rawPath": "/resource/path",
  "rawQueryString": "parameter1=value1&parameter1=value2&parameter2=value",
  "cookies": ["cookie1", "cookie2"],
  "headers": {
    "header1": "value1",
    "header2": "value1,value2",
    "Accept-Encoding": "deflate"
  },
  "requestContext": {
    "http": {
      "method": "POST"
    }
  },
  "body": "Payload",
  "isBase64Encoded": false
}
JSON

API_GATEWAY_V2_BASE64_REQUEST = <<-JSON
{
  "rawPath": "/resource/path",
  "rawQueryString": "parameter1=value1&parameter1=value2&parameter2=value",
  "cookies": ["cookie1", "cookie2"],
  "headers": {
    "header1": "value1",
    "header2": "value1,value2",
    "Accept-Encoding": "deflate"
  },
  "requestContext": {
    "http": {
      "method": "POST"
    }
  },
  "body": "UGF5bG9hZA==",
  "isBase64Encoded": true
}
JSON

private def assert_api_gateway_v1_request(context : HTTP::Server::Context)
  context.request.resource.should eq "/resource/path?parameter1=value1&parameter1=value2&parameter2=value"
  context.request.body.try(&.gets_to_end).should eq "Payload"
  context.request.headers.should eq HTTP::Headers{"Content-Length"  => "7",
                                                  "accept-encoding" => "deflate",
                                                  "header1"         => "value1",
                                                  "header2"         => ["value1", "value2"]}
end

private def assert_api_gateway_v2_request(context : HTTP::Server::Context)
  context.request.resource.should eq "/resource/path?parameter1=value1&parameter1=value2&parameter2=value"
  context.request.body.try(&.gets_to_end).should eq "Payload"
  context.request.headers.should eq HTTP::Headers{"Content-Length"  => "7",
                                                  "accept-encoding" => "deflate",
                                                  "header1"         => "value1",
                                                  "header2"         => "value1,value2"}
end

private def build_test_response(context : HTTP::Server::Context)
  context.response.status_code = 200
  context.response.content_type = "application/json"
  context.response.headers["header1"] = "value1"
  context.response.headers["header2"] = ["value1", "value2"]
  context.response.cookies["cookie1"] = "value1"
  context.response.cookies["cookie2"] = "value2"
  context.response.print %({"ans":)
  context.response.flush
  context.response.print %(42})
end

describe Crowbar do
  describe :process_http_request do
    it "handles uncaught exceptions" do
      test_handler = Proc(HTTP::Server::Context, Nil).new do |context|
        raise "Uncaught Error"
      end
      Crowbar.capture_log_output do
        LambdaTestServer.test_adapter(API_GATEWAY_V1_REQUEST, test_handler, Crowbar::APIGatewayV1Adapter) do |context|
          JSON.parse(context.request.body.not_nil!.gets_to_end).should eq JSON.parse(<<-JSON)
          {
            "statusCode": 500,
            "headers": {"Content-Type": "text/plain"},
            "body": "500 Internal Server Error\\n",
            "isBase64Encoded": false
          }
          JSON
        end
      end
    end
  end

  describe Crowbar::APIGatewayV1Adapter do
    it "parses requests with null query string parameters" do
      request = Crowbar::APIGatewayV1Adapter.parse_http_request IO::Memory.new(<<-JSON)
      {
        "path": "/resource/path",
        "httpMethod": "POST",
        "queryStringParameters": null,
        "multiValueQueryStringParameters": null,
        "body": "Payload",
        "isBase64Encoded": false
      }
      JSON

      request.path.should eq "/resource/path"
      request.query_params.should be_empty
      request.body.try(&.gets_to_end).should eq "Payload"
    end

    it "parses requests with a null body" do
      request = Crowbar::APIGatewayV1Adapter.parse_http_request IO::Memory.new(<<-JSON)
      {
        "path": "/resource/path",
        "httpMethod": "GET",
        "queryStringParameters": {"parameter1": "value1"},
        "multiValueQueryStringParameters": {"parameter1": ["value1"]},
        "body": null,
        "isBase64Encoded": false
      }
      JSON

      request.resource.should eq "/resource/path?parameter1=value1"
      request.body.should be_nil
    end

    it "adapts API Gateway v1 requests in single value header mode" do
      Crowbar::APIGatewayV1Adapter.multi_value_headers = false
      test_handler = LambdaTestServer::ErrorHandler.new do |context|
        assert_api_gateway_v1_request context
        build_test_response context
      end

      LambdaTestServer.test_adapter(API_GATEWAY_V1_REQUEST, test_handler, Crowbar::APIGatewayV1Adapter) do |context|
        JSON.parse(context.request.body.not_nil!.gets_to_end).should eq JSON.parse(<<-JSON)
        {
          "statusCode":200,
          "headers": {
            "Content-Type": "application/json",
            "header1": "value1",
            "header2": "value1,value2",
            "Set-Cookie": "cookie1=value1,cookie2=value2"
          },
          "body": "{\\"ans\\":42}",
          "isBase64Encoded": false
        }
        JSON
      end
    end

    it "adapts API Gateway v1 requests in multi value header mode" do
      Crowbar::APIGatewayV1Adapter.multi_value_headers = true
      test_handler = LambdaTestServer::ErrorHandler.new do |context|
        assert_api_gateway_v1_request context
        build_test_response context
      end

      LambdaTestServer.test_adapter(API_GATEWAY_V1_REQUEST, test_handler, Crowbar::APIGatewayV1Adapter) do |context|
        JSON.parse(context.request.body.not_nil!.gets_to_end).should eq JSON.parse(<<-JSON)
        {
          "statusCode":200,
          "multiValueHeaders": {
            "Content-Type": ["application/json"],
            "header1": ["value1"],
            "header2": ["value1", "value2"],
            "Set-Cookie": ["cookie1=value1", "cookie2=value2"]
          },
          "body": "{\\"ans\\":42}",
          "isBase64Encoded": false
        }
        JSON
      end
    end

    it "adapts API Gateway v1 requests with base64 encoded bodies" do
      Crowbar::APIGatewayV1Adapter.multi_value_headers = false
      handler = HTTP::CompressHandler.new
      handler.next = LambdaTestServer::ErrorHandler.new do |context|
        assert_api_gateway_v1_request context
        build_test_response context
      end

      LambdaTestServer.test_adapter(API_GATEWAY_V1_BASE64_REQUEST, handler, Crowbar::APIGatewayV1Adapter) do |context|
        JSON.parse(context.request.body.not_nil!.gets_to_end).should eq JSON.parse(<<-JSON)
        {
          "statusCode":200,
          "headers": {
            "Content-Type": "application/json",
            "header1": "value1",
            "header2": "value1,value2",
            "Content-Encoding": "deflate",
            "Set-Cookie": "cookie1=value1,cookie2=value2"
          },
          "body": "qlZKzCtWsgIAAAD//zIxqgUAAAD//wMA",
          "isBase64Encoded": true
        }
        JSON
      end
    end
  end

  describe Crowbar::ApplicationLoadBalancerAdapter do
    it "decodes query string parameters forwarded as sent by the client" do
      request = Crowbar::ApplicationLoadBalancerAdapter.parse_http_request IO::Memory.new(<<-JSON)
      {
        "path": "/resource/path",
        "httpMethod": "GET",
        "queryStringParameters": {
          "q": "a%20b%26c",
          "plus": "a+b",
          "redirect%5Burl%5D": "https%3A%2F%2Fexample.com"
        },
        "headers": {"header1": "value1"},
        "body": "",
        "isBase64Encoded": false
      }
      JSON

      request.query_params["q"].should eq "a b&c"
      request.query_params["plus"].should eq "a b"
      request.query_params["redirect[url]"].should eq "https://example.com"
    end

    it "decodes multi value query string parameters" do
      request = Crowbar::ApplicationLoadBalancerAdapter.parse_http_request IO::Memory.new(<<-JSON)
      {
        "path": "/resource/path",
        "httpMethod": "GET",
        "multiValueQueryStringParameters": {"q": ["a%20b", "c%26d"]},
        "multiValueHeaders": {"header1": ["value1"]},
        "body": "",
        "isBase64Encoded": false
      }
      JSON

      request.query_params.fetch_all("q").should eq ["a b", "c&d"]
    end

    it "serializes responses using its own multi value header setting" do
      Crowbar::APIGatewayV1Adapter.multi_value_headers = false
      Crowbar::ApplicationLoadBalancerAdapter.multi_value_headers = true
      test_handler = LambdaTestServer::ErrorHandler.new do |context|
        context.response.content_type = "text/plain"
        context.response.print "ok"
      end

      LambdaTestServer.test_adapter(API_GATEWAY_V1_REQUEST, test_handler, Crowbar::ApplicationLoadBalancerAdapter) do |context|
        JSON.parse(context.request.body.not_nil!.gets_to_end).should eq JSON.parse(<<-JSON)
        {
          "statusCode": 200,
          "multiValueHeaders": {"Content-Type": ["text/plain"]},
          "body": "ok",
          "isBase64Encoded": false
        }
        JSON
      end
    ensure
      Crowbar::ApplicationLoadBalancerAdapter.multi_value_headers = false
    end
  end

  describe Crowbar::APIGatewayV2Adapter do
    it "adapts API Gateway v2 requests" do
      test_handler = LambdaTestServer::ErrorHandler.new do |context|
        assert_api_gateway_v2_request context
        build_test_response context
      end

      LambdaTestServer.test_adapter(API_GATEWAY_V2_REQUEST, test_handler, Crowbar::APIGatewayV2Adapter) do |context|
        JSON.parse(context.request.body.not_nil!.gets_to_end).should eq JSON.parse(<<-JSON)
        {
          "statusCode":200,
          "headers": {
            "Content-Type": "application/json",
            "header1": "value1",
            "header2": "value1,value2"
          },
          "cookies": ["cookie1=value1", "cookie2=value2"],
          "body": "{\\"ans\\":42}",
          "isBase64Encoded": false
        }
        JSON
      end
    end

    it "adapts API Gateway v2 requests with base64 encoded responses" do
      handler = HTTP::CompressHandler.new
      handler.next = LambdaTestServer::ErrorHandler.new do |context|
        assert_api_gateway_v2_request context
        build_test_response context
      end

      LambdaTestServer.test_adapter(API_GATEWAY_V2_BASE64_REQUEST, handler, Crowbar::APIGatewayV2Adapter) do |context|
        JSON.parse(context.request.body.not_nil!.gets_to_end).should eq JSON.parse(<<-JSON)
            {
              "statusCode":200,
              "headers": {
                "Content-Type": "application/json",
                "header1": "value1",
                "header2": "value1,value2",
                "Content-Encoding": "deflate"
              },
              "cookies": ["cookie1=value1", "cookie2=value2"],
              "body": "qlZKzCtWsgIAAAD//zIxqgUAAAD//wMA",
              "isBase64Encoded": true
            }
            JSON
      end
    end
  end

  describe Crowbar::LambdaURLStreamingAdapter do
    it "adapts Lambda URL streaming requests" do
      test_handler = LambdaTestServer::ErrorHandler.new do |context|
        assert_api_gateway_v2_request context
        build_test_response context
      end

      LambdaTestServer.test_adapter(API_GATEWAY_V2_REQUEST, test_handler, Crowbar::LambdaURLStreamingAdapter) do |context|
        raw_body = context.request.body.as(HTTP::ChunkedContent).io
        raw_body.gets(chomp: false).should eq "a4\r\n"
        raw_body.gets(chomp: false).should eq %({"statusCode":200,"headers":{"Content-Type":"application/json","header1":"value1","header2":"value1, value2"},"cookies":["cookie1=value1","cookie2=value2"]}\u0000\u0000\u0000\u0000\u0000\u0000\u0000\u0000\r\n)
        raw_body.gets(chomp: false).should eq "7\r\n"
        raw_body.gets(chomp: false).should eq %({"ans":\r\n)
        raw_body.gets(chomp: false).should eq "3\r\n"
        raw_body.gets(chomp: false).should eq %(42}\r\n)
        raw_body.gets(chomp: false).should eq "0\r\n"
        raw_body.gets(chomp: false).should eq "\r\n"
      end
    end
  end
end
