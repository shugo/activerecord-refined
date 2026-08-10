# Downloads the wasi-sdk into the build tree and prints where it landed.
#
# bin/build-wasm needs it before rbwasm runs, to compile SQLite for
# wasm32-wasi.  rbwasm would fetch it on its own, but only once it gets to
# building Ruby -- by which point the SQLite step has already had to run.
#
# The version is read from rbwasm's own table for the "head" source, which is
# what a local Ruby checkout is treated as, so the two cannot drift apart.
require "fileutils" # toolchain.rb uses FileUtils but leaves requiring it to its caller
require "ruby_wasm"
require "ruby_wasm/cli"

build_dir = ARGV.fetch(0)

version = RubyWasm::CLI
  .build_config_aliases(Dir.pwd)
  .fetch("head")
  .fetch(:wasi_sdk_version)

path = File.join(build_dir, "toolchain", "wasi-sdk-#{version}")

# rbwasm reports what it downloads on stdout, which is where the caller is
# looking for the path.  Keep the two apart.
real_stdout = $stdout
$stdout = $stderr

toolchain = RubyWasm::WASISDK.new(nil, build_dir: build_dir, version: version)
toolchain.install_wasi_sdk(RubyWasm::BuildExecutor.new(verbose: false))

real_stdout.puts path
