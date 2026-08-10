# Wrapper around the rbwasm CLI.
#
# json is a default gem in Ruby 4.1, and Ruby's own json extension is compiled
# into the binary (it is in RubyWasm::Packager::ALL_DEFAULT_EXTS).  Packaging
# the json *gem* on top puts its Ruby files ahead of the stdlib's while the C
# side stays at Ruby's version; the skew surfaces as
# "uninitialized constant JSON::Fragment" the moment ActiveSupport loads json.
#
# ActiveSupport depends on json, so it cannot simply be dropped from the
# Gemfile.  rbwasm's exclusion list is a plain constant, and `specs` is what
# both the gem packaging and the extension build read, so adding json there
# leaves Ruby's built-in json to do the job.
require "ruby_wasm"
require "ruby_wasm/cli"

# sqlite3 is excluded for a different reason: it is in the Gemfile only so that
# bin/build-wasm can take its C sources and bundled SQLite amalgamation, and
# bin/prepare-rb its Ruby files.  The extension is built inside Ruby's own ext
# tree, so rbwasm must not try to build or package the gem.
RubyWasm::Packager::EXCLUDED_GEMS.concat(%w[json sqlite3])

RubyWasm::CLI.new(stdout: $stdout, stderr: $stderr).run(ARGV)
