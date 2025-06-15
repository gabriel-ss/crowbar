#!/usr/bin/env crystal
require "./arg_parser"
require "ecr"

options = Options.from_args(ARGV)

dockerfile = {{ read_file("#{__DIR__}/Dockerfile") }}
containerized_build_script = options.as_receiver { ECR.render("#{__DIR__}/containerized_build.sh.ecr") }
run_build_script = ECR.render("#{__DIR__}/build.sh.ecr")

INHERIT_STDIO = {
  input:  Process::Redirect::Inherit,
  output: Process::Redirect::Inherit,
  error:  Process::Redirect::Inherit,
}

CONTAINER_COMMAND = Process.find_executable("podman") ? "podman" : "docker"

def container(*args : String, **kwargs)
  status = Process.run(CONTAINER_COMMAND, args, **INHERIT_STDIO.merge(kwargs))
  raise "#{CONTAINER_COMMAND} exited with status #{status.exit_code}" unless status.success?
end

case options.command
in .build?
  container_name = "crowbar_build_#{Random::Secure.hex(4)}"

  container "build", "--tag", "crowbar_build", "-", input: IO::Memory.new(dockerfile)
  container "run", "--name", container_name, "-dit", "--rm", "crowbar_build", "/bin/bash"

  begin
    container "cp", "./.", "#{container_name}:/var/task"
    container "exec", container_name, "/bin/bash", "-c", containerized_build_script
    container "cp", "#{container_name}:/bundle.zip", options.output
  ensure
    container "stop", container_name
  end
in .plan?
  File.write("Dockerfile", dockerfile)
  File.write("build.sh", run_build_script)
end
