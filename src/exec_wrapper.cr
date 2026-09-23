# Managed Lambda runtimes start through the program named in
# `AWS_LAMBDA_EXEC_WRAPPER` (wrapper scripts, see
# https://docs.aws.amazon.com/lambda/latest/dg/runtimes-modify.html). OS-only
# runtimes do not: the function's own binary is the runtime, so nothing reads
# the variable. Crowbar is that runtime, so it honours the variable itself:
# the process re-execs once through the wrapper, with its own command line as
# the arguments, and marks the environment so that the start the wrapper hands
# back to proceeds normally.
#
# This file is the first thing `crowbar` requires, so it runs before anything
# that follows `require "crowbar"` in the program.
private CROWBAR_EXEC_WRAPPER_APPLIED = "CROWBAR_EXEC_WRAPPER_APPLIED"

if (wrapper = ENV["AWS_LAMBDA_EXEC_WRAPPER"]?.presence) && !ENV.has_key?(CROWBAR_EXEC_WRAPPER_APPLIED)
  executable = Process.executable_path || abort("crowbar: cannot resolve the path of the running executable to start through AWS_LAMBDA_EXEC_WRAPPER")

  begin
    Process.exec(wrapper, [executable, *ARGV], env: {CROWBAR_EXEC_WRAPPER_APPLIED => "1"})
  rescue ex : IO::Error
    abort("crowbar: could not start through AWS_LAMBDA_EXEC_WRAPPER=#{wrapper}: #{ex.message}")
  end
end
