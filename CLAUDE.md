# Guidelines

## Repository

- origin = shugo/activerecord-refined.  Pull requests are usually created
  by Shugo himself; do not create one unless asked.
- Do not change the CI workflow (`.github/workflows/`) to run work in
  progress - no temporary branch triggers.  To reach CI for a change only CI
  can verify, such as an adapter with no local server, ask first, then open a
  draft pull request; the standing `pull_request` trigger runs the suite on
  it, and the draft says it is not yet up for merge.  When the work is done
  and CI is green, mark the pull request ready for review (`gh pr ready`) so
  Shugo can take it; reviewing and merging stay his.
- Work happens on `master`.  The gem was formerly `activerecord-refinements`
  by Akira Matsuda; the History section of the README is the only place that
  needs to know.
- `Proc#refined` is a Ruby 4.1 feature, so the whole gem needs a ruby-master
  build: `.ruby-version` says `master`, which rbenv resolves to one here.
  `sandbox/.ruby-version` says 4.0 on purpose - see sandbox/README.md.
- /workspace/ruby is Shugo's own CRuby checkout and may be mid-build.  Never
  build in it, never switch its branch, never delete anything under it.  A
  separate clone elsewhere costs nothing.
- Keep scratch files out of the working tree; the session scratchpad is for
  them.  `git add -A` is never the right command in this repository -
  sandbox/ generates tens of thousands of files that are gitignored, and one
  slip has already cost a history rewrite.

## Commits

- English, imperative mood.
- End the message with a single trailer naming the model actually in use,
  e.g. `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`, and nothing
  after it - no session URLs, no Claude-Session line, no "Generated with"
  lines.
- If the message contains backticks or other shell metacharacters, write it
  to a file and use `git commit -F <file>`; passing it with `-m` can
  silently lose words.
- Keep commit messages and code comments ASCII.  Prose in the README may use
  what it needs.
- Before any force-push, verify the remote SHA with `git ls-remote` and use
  `--force-with-lease`.
- Do not commit or push until asked; finish the change, run the
  verification, and report.

## Comments and prose

- A comment must say something the code cannot: a constraint, or the reason
  a thing is the way it is.  Longer than CRuby's norm is fine here, but only
  where there is something to say.
- Do not document what is absent.  If a method is not defined, the code
  already says so; explaining the omission is a comment Shugo deletes.
- The docstring carries the user-facing explanation and the comment below
  it carries the constraint.  A public method's comment opens with what it
  builds -- one sentence, the SQL, an `@example` -- and the constraint, when
  there is one, follows after a bare `#` line; YARD shows the first
  paragraph as the summary.  Neither half should be a copy of the other,
  and neither should repeat the guide in `docs/`.
- A method made by `define_method` is invisible to YARD and gets a
  `@!method` directive in the comment above the table that makes it; a
  method inside `refine Symbol do ... end` likewise, declared on
  `BlockSyntax` outside the block.  A constant that is a lookup table or a
  pattern is tagged `@private`, so that the reference lists what a user
  writes and nothing else.  `bundle exec yard doc -n` says what is
  undocumented; `yard server --reload` shows the result.
- Rationale, rejected alternatives and history go in the commit message, not
  in the code.
- A Markdown table needs a header row with something in it.  GitHub renders
  an empty one, `| | |`, and so does every markdown library YARD picks from,
  but rubydoc.info leaves such a table as raw pipes while rendering the
  tables beside it.

## Tests

```sh
rake test                    # sqlite3, the default
ADAPTER=postgresql rake test
ADAPTER=mysql2 rake test     # MariaDB
rake test:mysql8             # Oracle's MySQL, on 3307
rake test:all                # all of the above; MySQL skipped when 3307 is empty
```

- Run all of them before reporting anything about the DSL.  The skips are
  adapter-specific and intended; PostgreSQL skips nothing.
- Every client gem sits in an optional bundler group named after its
  adapter, so the server legs need a one-time
  `bundle config set --local with postgresql mysql2 trilogy` -- already done
  in this devcontainer.  Oracle and SQL Server have no local server and run
  on CI only.
- `ADAPTER=mysql2` here reaches MariaDB; `rake test:mysql8` reaches Oracle's
  MySQL on 3307, in a devcontainer rebuilt since it was added -- test:all
  says so and moves on when it is not there.  The two differ over JSON, where
  MariaDB's json column is a checked longtext that Active Record will not
  serialise a hash into and MySQL's is a type of its own that wants one, and
  over cast, where MariaDB takes integer and MySQL knows only signed.
  `connection.mariadb?` tells them apart.
- Never assert an adapter's own spelling.  `greatest` is `MAX` on SQLite and
  the apostrophe in a quoted string is escaped three different ways, so a
  regexp that passes on SQLite can fail on the other two.  Assert something
  spelled the same everywhere, or assert the value that comes back.
- A test that checks a refinement is confined to the block should call the
  method outside one and expect `NoMethodError`.

## Examples

- `examples/*.rb` are runnable and each prints the SQL it builds.  All but
  `postgresql.rb` need nothing but SQLite.
- New DSL surface belongs in four places: the docstring, the guide under
  `docs/` for its topic (the README carries none of this -- it points at
  rubydoc.info, whose front page is `docs/index.md`), `examples/`, and
  `sandbox/examples.js`.  An example that only builds a relation and never
  prints prints nothing; `sandbox/check-examples.mjs` will say so.

## Sandbox

sandbox/README.md is the reference.  What matters when changing the gem:

- Changing `lib/` calls for `./bin/prepare-rb` only, not the ~20 minute
  `./bin/build-wasm`: `rb/lib` is assembled from `../lib` at prepare time.
- `npm run check` runs every example in `examples.js` on the real wasm
  build.  Run it after touching `lib/` or `examples.js`.
- Nothing generated is committed: `ruby.wasm`, `rb/`, `manifest.json`,
  `assets/`, `build/`, `rubies/`, `node_modules/`, `vendor/`.
- The page is on GitHub Pages and `ruby.wasm` on Cloudflare R2 behind
  `wasm.shugo.net`, because the binary is 40 MB and everything else together
  is under 200 KB.
- `sandbox/` is excluded from the gem by the gemspec.

## Releasing

```sh
bundle exec bump patch --tag  # or bump minor
git push --follow-tags
```

A `v*` tag runs `.github/workflows/push_gem.yml`, which publishes through
RubyGems.org's trusted publishing, so no API key is stored anywhere.  Check
what has landed since the last tag before choosing the level: a release that
adds DSL surface is a minor, not a patch.
