require "./spec_helper"

# The re-exec can only be observed from outside the process, so these specs
# build a tiny program that requires crowbar and run it as Lambda would.
private module WrappedProgram
  # `require` only takes relative paths, so the program is written next to this spec.
  SOURCE = <<-'CRYSTAL'
    require "../src/crowbar"

    puts "args=#{ARGV.join(",")} applied=#{ENV["CROWBAR_EXEC_WRAPPER_APPLIED"]? || "no"}"
    exit ARGV.first?.try(&.to_i?) || 0
    CRYSTAL

  @@binary : String?

  def self.binary : String
    @@binary ||= build
  end

  private def self.build : String
    source = File.join(__DIR__, ".exec_wrapper_program.cr")
    binary = File.tempname("crowbar-exec-wrapper-program")
    File.write(source, SOURCE)

    output = IO::Memory.new
    status = Process.run("crystal", ["build", source, "-o", binary], output: output, error: output)
    File.delete?(source)
    raise "failed to build the wrapped program:\n#{output}" unless status.success?

    at_exit { File.delete?(binary) }
    binary
  end

  # Runs the program with a clean environment plus *env*, returning its status and stdout.
  def self.run(args : Array(String), env : Hash(String, String)) : {Process::Status, String}
    output = IO::Memory.new
    error = IO::Memory.new
    status = Process.run(binary, args, env: env.merge({"PATH" => ENV["PATH"]}), clear_env: true, output: output, error: error)
    {status, output.to_s + error.to_s}
  end

  # Writes a wrapper script that appends its command line to *log* and execs it.
  def self.recording_wrapper(log : String) : String
    path = File.tempname("crowbar-wrapper", ".sh")
    File.write(path, <<-SH)
      #!/bin/sh
      echo "$*" >> #{Process.quote(log)}
      exec "$@"
      SH
    File.chmod(path, 0o755)
    path
  end
end

describe "AWS_LAMBDA_EXEC_WRAPPER support" do
  it "starts directly when the variable is unset or empty" do
    status, output = WrappedProgram.run(["0", "x"], {} of String => String)
    status.exit_code.should eq(0)
    output.should eq("args=0,x applied=no\n")

    status, output = WrappedProgram.run(["0"], {"AWS_LAMBDA_EXEC_WRAPPER" => ""})
    status.exit_code.should eq(0)
    output.should eq("args=0 applied=no\n")
  end

  it "re-execs once through the wrapper with its own command line" do
    log = File.tempname("crowbar-wrapper", ".log")
    wrapper = WrappedProgram.recording_wrapper(log)
    begin
      status, output = WrappedProgram.run(["7", "some", "arg"], {"AWS_LAMBDA_EXEC_WRAPPER" => wrapper})

      status.exit_code.should eq(7)
      output.should eq("args=7,some,arg applied=1\n")
      File.read_lines(log).should eq(["#{File.realpath(WrappedProgram.binary)} 7 some arg"])
    ensure
      File.delete?(log)
      File.delete?(wrapper)
    end
  end

  it "does not re-exec again when the wrapper hands control back" do
    log = File.tempname("crowbar-wrapper", ".log")
    wrapper = WrappedProgram.recording_wrapper(log)
    begin
      # The wrapper leaves AWS_LAMBDA_EXEC_WRAPPER set, as Lambda would; only the
      # marker keeps the second start from looping.
      status, _ = WrappedProgram.run(["0"], {"AWS_LAMBDA_EXEC_WRAPPER" => wrapper})

      status.exit_code.should eq(0)
      File.read_lines(log).size.should eq(1)
    ensure
      File.delete?(log)
      File.delete?(wrapper)
    end
  end

  it "fails at startup when the wrapper cannot be executed" do
    status, output = WrappedProgram.run(["0"], {"AWS_LAMBDA_EXEC_WRAPPER" => "/nonexistent/wrapper"})

    status.exit_code.should eq(1)
    output.should contain("crowbar: could not start through AWS_LAMBDA_EXEC_WRAPPER=/nonexistent/wrapper")
    output.should_not contain("applied=")
  end
end
