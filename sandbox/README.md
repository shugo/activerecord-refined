# activerecord-refined sandbox

A page that runs Ruby 4.1, ActiveRecord, SQLite and PostgreSQL inside the
browser so that
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
index.html         example list, editor, output
boot.rb            schema and seed data, the database switch, the show helper
examples.js        the examples
pglite/            the PostgreSQL adapter and what it is missing
pglite-bridge.mjs  the JS half of that adapter
manifest.json      list of the Ruby files written into the VM at boot   (generated)
rb/lib/**          their contents                                       (generated)
assets/            ruby.wasm's loader and CodeMirror                    (generated)
ruby.wasm          Ruby 4.1 + ActiveRecord + SQLite                  (generated, ~40 MB)
```

Each example has its own URL, so one can be linked to:
`https://shugo.github.io/activerecord-refined/#root-and-depth`. The fragment
is the example's `slug` in `examples.js`, written out rather than made from
the title: a link then survives the title being reworded, and stays short
however long the title is. Adding an example means adding a slug, and
`npm run check` says so if that slips.

`ruby.wasm` is large, so serve it with gzip or brotli enabled — it compresses
to about 12 MB.

## The two databases

The page starts on SQLite, which is compiled into `ruby.wasm` and costs
nothing more to load. PostgreSQL is [PGlite](https://pglite.dev) — PostgreSQL
itself compiled to WebAssembly — and is fetched from jsDelivr, about 5 MB, when
it is first chosen rather than by everyone who opens the page. Switching either
way rebuilds the schema and the sample data, so what the sidebar describes is
what is there.

The schemas are not quite identical: `posts.tags` is an array, which is a type
PostgreSQL has and SQLite has not, and `docs.meta` is `jsonb` there against
`json` here, since containment and the rest of the operators the JSON examples
use belong to `jsonb` alone.

The adapter is [wasmify-rails](https://github.com/palkan/wasmify-rails)'s,
vendored under `pglite/` unmodified: it subclasses `PostgreSQLAdapter` and
swaps only the connection for an object that calls out to JS, so the SQL
ActiveRecord builds and the results it reads are its own. `pglite.rb` beside it
adds what this needs on top — the array types, the array encoder and decoder
the pg stub does without, the quoting of every identifier rather than only the
ones that would otherwise be read wrongly (PostgreSQL folds an unquoted one to
lower case, so an alias asked for as `Author` came back as `author`), the
registration Rails 7.2 and later want in place of the `*_connection` hook, and
the translation of a failure into `StatementInvalid`, which is what `show` is
written to catch.

The gem itself needs one thing: `pglite` in `ADAPTER_FAMILIES`. Without it the
adapter is one nobody has classified and the block syntax falls back to the
standard spellings, so the page would be told PostgreSQL's JSON operators do
not exist.

**Everything that reaches the database goes through `evalAsync`.** PGlite
answers a query with a promise, which the Ruby side waits on with
`JS::Object#await`, and `await` unwinds the whole Ruby stack through asyncify
— only `evalAsync` picks it up again. So `vm.eval` is left for what cannot
touch a database, on both adapters.

**PGlite's own parsers are turned off.** Left on, they hand over what JS would
make of a value, which is not what ActiveRecord is about to do with it: a float
arrives as a JS number and is rounded to an integer, a timestamp as a Date and
is read back in the local zone, and jsonb as an object that comes out of `to_s`
as nothing ActiveRecord can parse. Parsing every type as itself hands over the
text PostgreSQL wrote, which is what the pg gem would have handed over.

The array types have to be named for this one by one, and named on each call:
PGlite parses an array whether or not a parser is registered for its type, and
only the options of the call itself are consulted for them — the ones
`PGlite.create` was given are not. What arrives when this is missed is a JS
array, which reaches Ruby through `to_s` as its elements joined by commas, so
`{a,"b,c"}` and `{a,b,c}` both come out as `a,b,c`.

A result read through the connection rather than through a model is not cast by
anyone, and with the parsers off it is text all the way down, so `show` and the
table pane ask for `cast_values`.

`bin/build-wasm` strips the binary at the end. rbwasm builds with `-g`
throughout, and the DWARF that leaves behind is about 21 MB, a third of the
file. Nobody is going to debug CRuby's C from the page, and this is the one
file whose size is worth caring about.

None of the generated files are committed. `bin/prepare-rb` assembles `rb/lib`
from `../lib` (the gem itself), the sqlite3 gem and `stubs/`, which means
**changing the gem only calls for re-running `bin/prepare-rb`** — no 64 MB
rebuild.

`.ruby-version` pins the host Ruby to 4.0. The repository root is on `master`,
but 4.1 cannot be used here: ruby_wasm's native extension depends on rb-sys,
which does not build against Ruby 4.1's headers. rbwasm is only a build tool,
so an older host has no bearing on the Ruby it produces being 4.1.

## Serving ruby.wasm from R2

The binary is 40 MB and everything else served from here together is under
200 KB, so it is essentially all of the bandwidth. Deployments put it in
Cloudflare R2, where egress is free, and serve only the page from GitHub Pages.
PGlite is nobody's build but its own and comes from jsDelivr, so it is not in
this at all.

The workflow skips the upload unless the repository variables are set, and the
page falls back to a `ruby.wasm` sitting next to it, so a checkout still works
with nothing configured.

### One-time setup

Create a bucket and give it a custom domain — **not** the `r2.dev` URL, which
Cloudflare rate-limits and documents as unsuitable for production, and which
gets no CDN caching:

```sh
npx wrangler r2 bucket create activerecord-refined-sandbox
npx wrangler r2 bucket cors set activerecord-refined-sandbox --file r2-cors.json
```

Then, in the Cloudflare dashboard, connect a custom domain to the bucket
(R2 → the bucket → Settings → Public access → Custom domain).

`r2-cors.json` lists the origins allowed to fetch the binary. Adjust it if the
page is served from somewhere other than `shugo.github.io`. It is in the shape
wrangler wants — a `rules` array of `{allowed: {origins, methods, headers}}` —
which is not the flat `AllowedOrigins` shape the dashboard shows for the same
setting.

Repository variables (Settings → Secrets and variables → Actions → Variables):

| Name | Example |
|------|---------|
| `R2_BUCKET` | `activerecord-refined-sandbox` |
| `R2_PUBLIC_URL` | `https://wasm.example.net` |

Secrets, on the same page. Create the token under R2 → **Manage R2 API
tokens** → **Create API token**, with **Object Read & Write** permission
scoped to this bucket alone; it hands back an access key id and a secret,
shown once:

| Name | Where it comes from |
|------|--------------------|
| `CLOUDFLARE_ACCOUNT_ID` | R2 overview in the dashboard |
| `R2_ACCESS_KEY_ID` | The token's Access Key ID |
| `R2_SECRET_ACCESS_KEY` | The token's Secret Access Key |

The upload goes through R2's S3-compatible API for the sake of that scoping.
Object Read & Write exists only on the S3 API — wrangler talks to Cloudflare's
REST API, which answers 403 to such a token and wants Admin Read & Write
instead, and that one can create and delete every bucket in the account.

### What the workflow does

The binary goes to `ruby-<hash of the build's inputs>.wasm` — of
`.ruby-version`, `Gemfile.lock`, `ext/`, and the scripts under `bin/` that
pin `RUBY_REV` and the toolchain versions. Not of the binary itself: the build
is not reproducible to the byte, and the same tree built twice came out 1 KB
apart, mtimes riding along in the packed filesystem. A hash of the output
would therefore change on every deploy and hand every visitor 12 MB to fetch
again for nothing, which is the whole thing the immutable caching is there to
avoid. Keyed on the inputs, the URL changes when the binary has a reason to.

That also means the build can be skipped. Before building, the workflow asks
R2 for the object under this key, and if it is there it takes it — a few
seconds against two minutes warm and sixteen cold. The examples are still
checked against the binary that comes down, which is what the run is really
for. Anything going wrong in the attempt — no credentials, as on a fork, or a
half-written file — falls through to building.

An object is therefore written once and never rewritten, which is what
`immutable` claims of it. Distinct keys have nothing to remove them, though,
and each is 12 MB, so the workflow deletes all but the newest three after
uploading one. Those three are the last three *builds* rather than the last
three deployments, which is a good deal longer — the inputs change rarely. It
is enough that a page fetched moments before a deploy still finds what it
wants, and that a bad build can be rolled back by pointing the page at the
previous key.

The objects are ordered by their timestamps. The key this run is using is
never deleted whatever its age says, since it need not have been uploaded
recently to be the one in use, and anything under the `ruby-` prefix that is
not one of these objects is left alone.

The page and the binary are deployed separately, so a visitor can briefly get
a new page with the previous binary. They are independent enough for that not
to matter — the binary only changes when the Gemfile or the pinned Ruby
revision does.

R2 serves what it is given and does not compress, so the binary is gzipped and
the encoding recorded on the object: 40 MB stored, about 12 MB on the wire.

The URL goes into the `<link rel="preload">` at the top of `index.html`, which
the workflow rewrites; the script fetches the binary by that element's href.
Naming it in the page rather than in a file the page has to read first means
the browser can start on the 12 MB while it is still parsing the head — 8 ms
into the load rather than 86 ms, measured locally, where a round trip costs
almost nothing. A checkout keeps the line as written and loads the `ruby.wasm`
beside it.

## Where PGlite comes from

Not from here. `ruby.wasm` is built in this repository and has to be put
somewhere; PGlite is the package as npm published it, so the page imports it
from jsDelivr at a version written into the `<meta name="pglite">` in the head:

```
https://cdn.jsdelivr.net/npm/@electric-sql/pglite@0.5.4/dist/index.js
```

The version in the URL is what makes it immutable, and jsDelivr serves it as
such — `max-age=31536000, immutable`, `access-control-allow-origin: *`, brotli
on the way out, which brings the 17 MB down to about 5 MB. Serving a copy could
only match that, at the cost of a hashed name to work out, eleven objects to
upload and old ones to age out — the files have to stay beside one another,
`index.js` finding its own `.wasm` and `.data` through `import.meta.url`.

`bin/prepare-rb` fails if that version is not the one in `node_modules`, since
that second one is what `npm run check` runs against and nothing else would
notice the two parting.

Deliberately not a preload: most visits never ask for it, so the URL is read
when PostgreSQL is chosen and imported then. `name` rather than `id` because an
element with an `id` becomes a property of `window` under it, and
`window.pglite` is where the adapter looks for its own object — an element
there is truthy, and the page would take it for a PGlite already loaded.

The page is therefore the only thing here that reaches outside the deployment,
and only when PostgreSQL is chosen: everything else, `ruby.wasm` included, is
served from R2 or from Pages.

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

**A download interrupted partway poisons the tree.** An interrupted transfer
leaves a half-unpacked directory as well as a short tarball, and rbwasm skips
fetching when the tarball is there and skips unpacking when the directory is
there, so the state never repairs itself. `bin/build-wasm` checks for the tool
inside — `wasm-opt`, `clang` — and clears both halves when it is missing.
Checking that the directory exists is exactly the wrong signal.

**A missing wasm-opt does not fail the build.** make prints `wasm-opt: not
found`, carries on, and the asyncify pass is quietly skipped. What comes out
looks like a normal ruby.wasm — it is roughly 52 MB instead of 62 MB and fails
at instantiation, on an `asyncify` import nothing can supply. This shipped
through a green CI run once. `bin/build-wasm` now rejects a binary that still
imports `asyncify`, which catches it however the pass came to be skipped.

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

All 25 examples can be run without opening a browser, on both databases. They
go through the same WASI shim the page uses, set up the same way, so anything
that passes here passes on the page.

```sh
npm run check
```

Features SQLite does not have — the regexp operators, `date_trunc`,
PostgreSQL's array operators — are supposed to raise `NotImplementedError` and
the like, so only unexpected exceptions such as `NoMethodError` or `NameError`
count as failures. An example that prints nothing is a failure too, which is
what says that one written to show a refusal is now running on the database
that has the thing.

`browser-check.html` runs both databases in a real browser, which is the only
place the JS stack depth and the asyncify path can be tested.
