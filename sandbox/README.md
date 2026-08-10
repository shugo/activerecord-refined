# activerecord-refined sandbox

A page that runs Ruby 4.1, ActiveRecord and SQLite inside the browser so that
[activerecord-refined](https://github.com/shugo/activerecord-refined)'s block
syntax can be tried out without installing anything.

`Proc#refined` is a Ruby 4.1 feature and Ruby 4.1 is not released yet, so the
gem cannot simply be `gem install`ed: trying it means building ruby-master
first. This sandbox is here to remove that step.

## Running it

```sh
bundle install
npm ci
./bin/build-wasm     # ~20 minutes the first time; later builds are cached
./bin/prepare-rb
npm run serve        # http://localhost:8000
```

A server is required because browsers refuse to load WebAssembly over
`file://`. Everything served is static; nothing runs on the server side.

```
index.html      example list, editor, output
boot.rb         schema and seed data for the in-memory SQLite database, the show helper
examples.js     the examples
manifest.json   list of the Ruby files written into the VM at boot   (generated)
rb/lib/**       their contents                                       (generated)
vendor/         the @ruby/wasm-wasi browser bundle                   (generated)
ruby.wasm       Ruby 4.1 + ActiveRecord + SQLite                     (generated, ~64 MB)
```

`ruby.wasm` is large, so serve it with gzip or brotli enabled.

None of the generated files are committed. `bin/prepare-rb` assembles `rb/lib`
from `../lib` (the gem itself), the sqlite3 gem and `stubs/`, which means
**changing the gem only calls for re-running `bin/prepare-rb`** — no 64 MB
rebuild.

`.ruby-version` pins the host Ruby to 4.0. The repository root is on `master`,
but 4.1 cannot be used here: ruby_wasm's native extension depends on rb-sys,
which does not build against Ruby 4.1's headers. rbwasm is only a build tool,
so an older host has no bearing on the Ruby it produces being 4.1.

## Build caching

The cross Ruby's build directory is named after a hash of **the gems that have
C extensions** and nothing else (see `packager/core.rb` in ruby_wasm) — not the
Gemfile as a whole, and not the Ruby source.

| Change | What gets rebuilt |
|---|---|
| `boot.rb`, `examples.js`, `index.html`, the gem itself | nothing |
| `ext/sqlite3-extconf.rb` or the staged sources | the extension, then the final link |
| a pure-Ruby gem in the Gemfile | nothing; the hash is unchanged |
| adding or removing a gem with a C extension | all of Ruby |
| `RUBY_REV` | effectively everything |

The final `wasm-ld` link runs every time and takes a few minutes. That is the
floor.

In CI, cache the Ruby checkout and the build tree **in the same entry**. make
decides by mtime, so restoring objects next to a freshly cloned Ruby rebuilds
everything. That is also why `bin/build-wasm` pins `RUBY_REV`.

## The gem is not baked into the binary

The `.rb` files under `rb/lib` are fetched when the page starts, written into
WASI's in-memory filesystem, and added to `$LOAD_PATH`.

The immediate reason is that `rbwasm build` already emits a wasi-vfs packed
binary, which cannot be packed a second time, and that the gem's
`required_ruby_version` of `>= 4.1.0.dev` keeps the host Bundler — which has to
run on Ruby 4.0 for rbwasm's sake — from resolving it at all.

It turned out to be an advantage: **editing the gem only calls for re-running
`bin/prepare-rb`**, not a 64 MB rebuild.

## Traps hit while getting this to build

`bin/build-wasm` needs nothing but a Rust toolchain; the wasi-sdk is downloaded
on first run. What follows is recorded with the reasoning because it is all
needed to reproduce the build. Most of it is one shape of problem: layering a
gem on top of something Ruby already ships breaks.

**The wasi-sdk has to be fetched before rbwasm runs.** SQLite is compiled for
wasm32-wasi before Ruby is built, but rbwasm only fetches the wasi-sdk once it
reaches the Ruby build. `bin/install-wasi-sdk.rb` pulls it in up front through
rbwasm's own downloader, so the version and the location stay in step.

**Everything goes under `build/`.** That is where rbwasm puts its own tree, so
the Ruby checkout and the SQLite artifacts go there too. make decides by mtime,
which means caching the objects apart from the sources they were built from
rebuilds everything -- one directory is what makes the tree cacheable in one
piece.

**A download interrupted partway poisons the tree.** rbwasm skips fetching when
the tarball is already there, so a short one left behind by a failed transfer
makes every later run fail in `tar` rather than retry. `bin/build-wasm` drops
tarballs that have nothing unpacked beside them; without that, CI would cache
the broken state and fail identically from then on.

**Use a clean clone of Ruby.** A tree you build in normally has a leftover
`prism/.time`. That file marks the build directory as already created, and in
an out-of-tree build VPATH picks up the one in the source tree — so `prism/` is
never created under the build directory and not one `prism/*.o` can be written.
`.time` is gitignored, so `git status` looks clean.

**SQLite itself is a non-issue.** SQLite has handled `__wasi__` on its own
since 3.41, so the amalgamation compiles with wasi-sdk's clang unpatched (18
seconds).

**The sqlite3 gem cannot be built by rbwasm.** rbwasm builds gem extensions
outside Ruby's build tree, where mkmf cannot link a conftest at all — even
`have_func("rb_enc_raise")` comes back false — and sqlite3's extconf aborts
when its `find_library` check fails. It is staged into Ruby's own ext tree and
built as a bundled extension instead, where mkmf works.

**Bundled extensions get HAVE_\* in extconf.h rather than as `-D`.**
`backup.c` tests `HAVE_SQLITE3_BACKUP_INIT` on its first line and includes
headers only inside that guard, so it never reads extconf.h, compiles to an
empty object, and leaves `init_sqlite3_backup` undefined for `sqlite3.c` to
call. Clearing `$extconf_h` does not help — mkmf runs
`create_header if $extmk and not $extconf_h`. `ext/sqlite3-extconf.rb` puts the
macros on the command line as well.

**Do not package the json gem.** Ruby 4.1 ships json as a default gem and its C
extension is compiled into the binary. Layering the gem's Ruby files on top
leaves the Ruby and C sides at different versions, which surfaces as
`uninitialized constant JSON::Fragment` while ActiveSupport loads. ActiveSupport
depends on json so it cannot be dropped from the Gemfile;
`bin/rbwasm-build.rb` adds it to `RubyWasm::Packager::EXCLUDED_GEMS` instead.

Cross-compiling the json gem is no way out either: because of the conftest
problem above, every `#ifndef HAVE_x` compatibility shim is emitted as a static
declaration and clashes with the real one — `ruby_xfree_sized` in 2.20 and
later, `rb_hash_bulk_insert` in 2.18, wasi-libc's `strnlen` in 2.15.

**Pin minitest to 5.x.** ActiveSupport depends on minitest, and minitest 6
depends on the prism gem. Linking its static library next to Ruby 4.1's
built-in prism gives `duplicate symbol: pm_buffer_*`.

## What the page needs at runtime

The three things at the top of `boot.rb` are all needed to run ActiveRecord on
Ruby under WASI.

- **`require "rubygems"`** — ruby.wasm starts with RubyGems disabled, so `Gem`
  is undefined, but ActiveSupport's BacktraceCleaner reads `Gem.path`.
- **Registering `Gem.loaded_specs['sqlite3']`** — sqlite3 is built in as a
  bundled extension rather than installed as a gem, so RubyGems cannot see it,
  and ActiveRecord's adapter opens with `gem "sqlite3", ">= 2.1"`. `Kernel#gem`
  returns early when `Gem.loaded_specs` already satisfies the requirement.
- **`reaping_frequency: nil`** — the connection pool's reaper runs on a
  `Thread`, and WASI has no threads (`Thread.new` raises
  `NotImplementedError`).

`rb/lib/socket.rb` is a stub for the same sort of reason. WASI has no sockets
so Ruby's socket extension is not built, but ActiveSupport reaches `ipaddr` on
its way through `core_ext/object/json`, and `ipaddr` only reads constants such
as `Socket::AF_INET`.

## JS stack depth

**Verified on Firefox 140.**

There is not much headroom. Compiling ActiveRecord's `relation.rb` needs about
**1.2 MB of JS stack**. Node's default (about 984 KB) raises
`RangeError: Maximum call stack size exceeded`, and `--stack-size=4000` was
needed. This is ActiveRecord's code, not the gem's, and switching to
`--parser=parse.y` makes no difference.

Chrome has not been tested. V8's default stack there is in the same range as
Node's, so that is where trouble would show up. With Chrome at hand, open
`browser-check.html` to find out — the result is posted to `devserver.mjs`'s
`/__result` and printed in the server log.

```sh
node devserver.mjs
# then open http://localhost:8000/browser-check.html in the browser to test
```

## Checking the examples

All 25 examples can be run without opening a browser. They go through the same
WASI shim the page uses, set up the same way, so anything that passes here
passes on the page.

```sh
npm run check
```

Features SQLite does not have — the regexp operators, `date_trunc`,
PostgreSQL's array operators — are supposed to raise `NotImplementedError` and
the like, so only unexpected exceptions such as `NoMethodError` or `NameError`
count as failures.
