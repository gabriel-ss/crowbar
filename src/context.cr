module Crowbar(T)
  class Context
    class CognitoIdentity
      include JSON::Serializable

      @[JSON::Field(key: "cognitoIdentityId")]
      getter cognito_identity_id : String

      @[JSON::Field(key: "cognitoIdentityPoolId")]
      getter cognito_identity_pool_id : String
    end

    class ClientApplication
      include JSON::Serializable

      getter installation_id : String
      getter app_title : String
      getter app_version_name : String
      getter app_version_code : String
      getter app_package_name : String
    end

    class ClientContext
      include JSON::Serializable

      getter client : ClientApplication
      getter env : Hash(String, String)
      getter custom : Hash(String, String)
    end

    getter function_name : String
    getter function_version : String
    getter memory_limit_in_mb : UInt32
    getter log_group_name : String
    getter log_stream_name : String
    getter aws_request_id : String
    getter invoked_function_arn : String
    getter deadline : Time
    getter identity : CognitoIdentity?
    getter client_context : ClientContext?

    private FUNCTION_NAME      = ENV["AWS_LAMBDA_FUNCTION_NAME"]
    private FUNCTION_VERSION   = ENV["AWS_LAMBDA_FUNCTION_VERSION"]
    private MEMORY_LIMIT_IN_MB = UInt32.new(ENV["AWS_LAMBDA_FUNCTION_MEMORY_SIZE"])
    private LOG_GROUP_NAME     = ENV["AWS_LAMBDA_LOG_GROUP_NAME"]
    private LOG_STREAM_NAME    = ENV["AWS_LAMBDA_LOG_STREAM_NAME"]

    def initialize(
      @function_name,
      @function_version,
      @memory_limit_in_mb,
      @log_group_name,
      @log_stream_name,
      @aws_request_id,
      @invoked_function_arn,
      @deadline,
      @identity,
      @client_context
    )
    end

    def self.new(invocation : HTTP::Client::Response)
      new(
        function_name: FUNCTION_NAME,
        function_version: FUNCTION_VERSION,
        memory_limit_in_mb: MEMORY_LIMIT_IN_MB,
        log_group_name: LOG_GROUP_NAME,
        log_stream_name: LOG_STREAM_NAME,
        aws_request_id: invocation.headers["Lambda-Runtime-Aws-Request-Id"],
        invoked_function_arn: invocation.headers["Lambda-Runtime-Invoked-Function-Arn"],
        deadline: Time.unix_ms(Int64.new(invocation.headers["Lambda-Runtime-Deadline-Ms"])),
        identity: invocation.headers["Lambda-Runtime-Cognito-Identity"]?.try { |json| CognitoIdentity?.from_json(json) },
        client_context: invocation.headers["Lambda-Runtime-Client-Context"]?.try { |json| ClientContext?.from_json(json) },
      )
    end
  end
end
