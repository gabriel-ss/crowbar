require "option_parser"
require "yaml"

class Options
  enum Command
    Build
    Plan
  end

  getter parser = OptionParser.new

  getter target_arch = "x86_64"
  getter files_to_bundle = [] of String
  getter dynamic_libraries = [] of String
  getter extra_packages = [] of String
  getter target : String = YAML.parse(File.read("shard.yml"))["targets"].as_h.keys.first.as_s
  getter shards_args = [] of String
  getter output = "."
  getter command = Command::Plan

  private def build_args
    parser.on("-t TARGET", "--build-target=TARGET", <<-DOC) { |value| @target = value }
      The target to be built. Defaults to the first target specified
      in shard.yml
      DOC

    parser.on("-a ARCH", "--target-arch=ARCH", <<-DOC) { |value| @target_arch = value }
      The target architecture for the resulting binary.
      Possible values: x86_64 (default), aarch64
      DOC

    parser.on("-f FILE", "--file-to-bundle=FILE", <<-DOC) { |value| @files_to_bundle << value }
      Additional files or folders to be included in the bundle. They
      will be copied to the root of the bundle and will be available
      at runtime in the initial working directory of the lambda.

      E.g.: -f LICENSE -f images/logo.png -f assets/ will make the
      files available at ./LICENSE, ./logo.png and ./assets/ respectively.

      Can be used multiple times.
      DOC

    parser.on("-d LIB", "--dynamic-library=LIB", <<-DOC) { |value| @dynamic_libraries << value }
      Additional dynamic libraries (.so files) to be included in the
      bundle. They will be copied to the root of the bundle and will
      be available at runtime in the initial working directory of
      the lambda.

      Can be used multiple times.
      DOC

    parser.on("-e PKG", "--extra-package=PKG", <<-DOC) { |value| @extra_packages << value }
      Extra packages from amazon linux 2023 repository to install in
      the build container. Useful for installing native dependencies.
      Available packages can be found at:
      https://docs.aws.amazon.com/linux/al2023/release-notes/all-packages.html

      Can be used multiple times.
      DOC

    parser.on("-o PATH", "--OUTPUT=PATH", <<-DOC) { |value| @output = value }
      Path to the output zip file. Defaults to ./bundle.zip
      DOC
  end

  private def args
    parser.banner = <<-BANNER
      Usage: #{PROGRAM_NAME} [arguments] [--] [...shards build arguments]

      A tool for building AWS Lambda functions written in Crystal targeting
      Amazon Linux 2023 provided runtime using docker/podman.

      Examples:
      #{PROGRAM_NAME} -a aarch64 -f assets -e libgit2-devel -- --production --release

      Arguments:
      BANNER

    parser.on("build", <<-DOC) { build_args; @command = Command::Build }
      Build the project and create a bundle to be deployed to AWS.
      DOC

    parser.on("plan", <<-DOC) { build_args; @command = Command::Plan }
      Take the same arguments as build, but instead of creating a
      bundle, it outputs a Dockerfile and a build script that can
      be further customized.
      DOC

    parser.on("-h", "--help", "Show this help") do
      puts parser
      exit
    end
  end

  def parse(args : Array(String))
    if (splitter_index = args.index("--")).nil?
      args_to_parse = args
    else
      args_to_parse = args[...splitter_index]
      @shards_args = args[(splitter_index + 1)..]
    end

    self.args
    parser.parse args_to_parse
  end

  def self.from_args(args : Array(String))
    options = new
    options.parse args
    options
  end

  def as_receiver(&)
    with self yield
  end
end
