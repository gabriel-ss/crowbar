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

def docker(*args : String, **kwargs)
  status = Process.run("docker", args, **INHERIT_STDIO.merge(kwargs))
  raise "docker exited with status #{status.exit_code}" unless status.success?
end

case options.command
in .build?
  container_name = "crowbar_build_#{Random::Secure.hex(4)}"

  docker "build", "--tag", "crowbar_build", "-", input: IO::Memory.new(dockerfile)
  docker "run", "--name", container_name, "-dit", "--rm", "crowbar_build", "/bin/bash"

  begin
    docker "cp", "./.", "#{container_name}:/var/task"
    docker "exec", container_name, "/bin/bash", "-c", containerized_build_script
    docker "cp", "#{container_name}:/bundle.zip", options.output
  ensure
    docker "stop", container_name
  end
in .plan?
  File.write("Dockerfile", dockerfile)
  File.write("build.sh", run_build_script)
end
