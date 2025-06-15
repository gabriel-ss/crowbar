![Logo](logo.svg)

Crowbar is an AWS Lambda runtime focused on efficiency, type safety and developer friendliness. In addition to the runtime itself, this shard also includes adapters to deploy Crystal web apps as lambdas and a CLI to easily build projects to be deployed.

## Installation

1. Add the dependency to your `shard.yml`:

```yaml
dependencies:
  crowbar:
    github: gabriel-ss/crowbar
```

2. Run `shards install`

## Usage

### Simple example

```crystal
require "json"
require "crowbar"

class Event
  include JSON::Serializable

  getter operand : Int32
end

Crowbar.handle_events of_type: Event do |event, context|
  {result: event.operand + 1}
end

# Could also be a Proc:
# handler = ->(event : Event, context : Crowbar::Context) { {result: event.operand + 1} }
# Crowbar.handle_events with: handler
```

The included CLI can be used to build a project targeting the AWS `provided.al2023` runtime by using Docker/Podman. Either the `docker` or the `podman` command must be available to the current user.

```bash
# Build the project in a lambda compatible environment
bin/crowbar build -- --production --release

# Deploy bundle to aws
aws lambda update-function-code --function-name func --zip-file fileb://bundle.zip
```

The lambda can then be invoked:

```bash
aws lambda invoke --function-name func --cli-binary-format raw-in-base64-out --payload '{"operand": 14}' response.json
cat response.json # {"result":15}
```

### Input and output types

#### Input

The incoming type is specified by the `of_type` parameter. If `Bytes`, `String` or `IO` is given, the unparsed event is given to the block/proc:

```crystal
# aws lambda invoke --function-name func --cli-binary-format raw-in-base64-out --payload '"Hello"' response
Crowbar.handle_events of_type: Bytes do |event, context|
  puts event # => Bytes[34, 72, 101, 108, 108, 111, 34]
end
```

```crystal
# aws lambda invoke --function-name func --cli-binary-format raw-in-base64-out --payload '"Hello"' response
Crowbar.handle_events of_type: String do |event, context|
  puts event # => "Hello"
end
```

```crystal
# aws lambda invoke --function-name func --cli-binary-format raw-in-base64-out --payload '"Hello"' response
Crowbar.handle_events of_type: IO do |event, context|
  puts event.gets_to_end # => "Hello"
end
```

If any other type is specified, the runtime will try to instantiate the type by calling its `from_json` method with the input:

```crystal
record Event, ans : Int32 { include JSON::Serializable }

# aws lambda invoke --function-name func --cli-binary-format raw-in-base64-out --payload '{"ans": 42}' response
Crowbar.handle_events of_type: Event do |event, context|
  puts event.ans # => 42
end
```

```crystal
# aws lambda invoke --function-name func --cli-binary-format raw-in-base64-out --payload '{"ans": 42}' response
Crowbar.handle_events of_type: Hash(String, Int32) do |event, context|
  puts event["ans"] # => 42
end
```

```crystal
# aws lambda invoke --function-name func --cli-binary-format raw-in-base64-out --payload '{"ans": 42}' response
Crowbar.handle_events of_type: NamedTuple(ans: Int32) do |event, context|
  puts event[:ans] # => 42
end
```

```crystal
# aws lambda invoke --function-name func --cli-binary-format raw-in-base64-out --payload '{"ans": 42}' response
Crowbar.handle_events of_type: JSON::Any do |event, context|
  puts event["ans"].as_i # => 42
end
```

#### Output

The output type is automatically inferred from the return type of the block/proc and follows the same logic as the input one: if `Bytes`, `String` or `IO` is returned, the raw result will be written to the lambda output. Note that even when an `IO` is returned, the output is only written when the block/proc finishes its execution.

```crystal
# aws lambda invoke --function-name func --cli-binary-format raw-in-base64-out --payload '"anything"' response
Crowbar.handle_events of_type: JSON::Any do |event, context|
  "Lambda Output"
end

# cat response # => Lambda Output
```

For other types, the output is first serialized by calling the `to_json` instance method on the returned object.

```crystal
class Response
  include JSON::Serializable

  property ans : Int32

  def initialize(@ans); end
end

# aws lambda invoke --function-name func --cli-binary-format raw-in-base64-out --payload '"anything"' response
Crowbar.handle_events of_type: JSON::Any do |event, context|
  Response.new(42)
end

# cat response # => {"ans":42}
```

```crystal
# aws lambda invoke --function-name func --cli-binary-format raw-in-base64-out --payload '"anything"' response
Crowbar.handle_events of_type: JSON::Any do |event, context|
  {ans: 42}
end

# cat response # => {"ans":42}
```

### Streaming Response

All previous examples were for lambdas in buffered mode, but Crowbar also supports [response streaming](https://docs.aws.amazon.com/lambda/latest/dg/configuration-response-streaming.html). To put Crowbar into response streaming mode, simply pass the `writing_to` argument of the `handle_events` method to specify which type of output should be used. Valid values are `Crowbar::ResponseIO`, that can be used for lambdas in general, and `Crowbar::HttpResponseIO`, that allows defining extra parameters to lambda invoked through lambda URLs.

When `writing_to` is set, a third parameter becomes available to the block/proc, which is an IO of the specified type that can be written to:

```crystal
Crowbar.handle_events of_type: String, writing_to: Crowbar::ResponseIO do |event, context, io|
  io.content_type = "text/html"

  io.puts "<h1>Title</h1>"
  io.flush
  sleep 2.seconds
  io.puts "<p>Content</p>"
  io.flush
end
```

```crystal
Crowbar.handle_events of_type: String, writing_to: Crowbar::HttpResponseIO do |event, context, io|
  io.status_code = HTTP::Status::OK
  io.headers = HTTP::Headers{"Content-Type" => "text/html"}
  io.cookies = HTTP::Cookies{"flavor" => "chocolate"}
  io.cookies.not_nil!.["flavor"].expires = Time.utc(2025, 1, 1, 10, 10, 10)

  io.puts "<h1>Title</h1>"
  io.flush
  sleep 2.seconds
  io.puts "<p>Content</p>"
  io.flush
end
```

Writes to the IO will be reflected in the output of the lambda. Note that setting any property of the response IOs after some data has already been flushed has no effect; the metadata is written together with the first data write.

### Web Server Adapter

Crowbar also has an adapter layer that allows instances of `HTTP::Handler`/`HTTP::Server` from Crystal's standard library to be deployed behind AWS integrations such as API Gateway and ALB. To handle events using an HTTP server, simply call `handle_events` passing the server as the `with` parameter and the chosen adapter as the `using` parameter:

```crystal
require "crowbar"
require "crowbar/http"

server = HTTP::Server.new([
  HTTP::ErrorHandler.new,
  HTTP::LogHandler.new,
  HTTP::CompressHandler.new,
]) do |context|
  context.response.content_type = "application/json"
  context.response.headers["Target"] = "Moon"
  context.response.cookies["flavor"] = "chocolate"
  context.response.print %({"ans": 42})
end

Crowbar.handle_events with: server, using: Crowbar::LambdaURLAdapter
```

Note that the HTTP adapter layer must be explicitly included with `require "crowbar/http"`. The available `APIGatewayV1Adapter`, `APIGatewayV2Adapter`, `ApplicationLoadBalancerAdapter`, `LambdaURLAdapter` and
`LambdaURLStreamingAdapter`. For `APIGatewayV1Adapter` and `ApplicationLoadBalancerAdapter`, multi-value header can be enabled by setting the `multi_value_headers` property of the adapter to `true`. Be sure to also make the [corresponding configuration](https://docs.aws.amazon.com/elasticloadbalancing/latest/application/lambda-functions.html#multi-value-headers) in AWS.

### Building and Deploying

Building a Crystal project in a way to make it compatible with the AWS custom lambda runtimes poses some challenges. To streamline the process, Crowbar includes a CLI tool that leverages docker to generate a bundle, ready to be deployed to AWS. For a simple project, a production build can be generated with:

```bash
bin/crowbar build -- --production --release
```

which outputs a file named `bundle.zip` compatible with the Amazon Linux 2023 Custom Runtime on an x86_64 architecture. The CLI also allows cross-compilation targeting arm64, for a full list of available options, check the `--help` of the build command.

The first execution of Crowbar's build will create the build environment from scratch using one of the official AWS runtime images, so it can take some minutes to complete the process. Subsequent executions will use the already built environment, so they should not add more than a few seconds compared to building outside a container.

The build command tries to be flexible enough to cover the vast majority of use cases by offering a variety of options to customize the process. Nonetheless, if for whatever reason you need full control over your build process, the CLI also has a `plan` command. It takes the same arguments of `build`, but instead of building the project, it generates a Dockerfile and a build script that perform the same process executed by Crowbar, allowing for further customization.

The generated zip file includes, in addition to other specified assets, both the built project and necessary dependencies, so it can be directly deployed to AWS. Unlike AWS provided runtimes such as python or node, Crowbar is directly linked against the user's event handler, so the `handler` parameter configured on the lambda isn't used by the runtime. Its value can be retrieved from the `_HANDLER` environment variable, though.

## Contributing

1. Fork it (<https://github.com/gabriel-ss/crowbar/fork>)
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create a new Pull Request

## Contributors

- [Gabriel Silveira](https://github.com/gabriel-ss) - creator and maintainer
