# ActiveRecord::Refined

[![gem](https://img.shields.io/gem/v/activerecord-refined.svg)](https://rubygems.org/gems/activerecord-refined)
[![test](https://github.com/shugo/activerecord-refined/actions/workflows/test.yml/badge.svg)](https://github.com/shugo/activerecord-refined/actions/workflows/test.yml)

Adding clean and powerful query syntax on Active Record using refinements.

```ruby
Author.
  joins(:posts) { :posts[:author_id] == :authors[:id] }.
  where { :authors[:age].in?(20..40) & (:posts[:published] == true) }
# SELECT "authors".* FROM "authors"
#   INNER JOIN "posts" ON "posts"."author_id" = "authors"."id"
#   WHERE "authors"."age" BETWEEN 20 AND 40 AND "posts"."published" = TRUE
```

**[Try it in your browser](https://shugo.github.io/activerecord-refined/)** —
Ruby 4.1, Active Record, SQLite and PostgreSQL run in the page, so the examples
build real SQL and return real rows without a `ruby-master` build of your own.

## History

This gem was formerly known as **activerecord-refinements**, created by Akira Matsuda
to experiment with the initial implementation of Ruby 2.0 Refinements. Because of the
Refinements' spec change, that implementation stopped working on Ruby 2.0.0 stable, and
the project was left dormant for a long time.

It has now been renamed to **activerecord-refined** and reimplemented on top of
[`Proc#refined`](https://docs.ruby-lang.org/en/master/Proc.html#method-i-refined),
which will be introduced in Ruby 4.1. `Proc#refined` returns a new proc that
is evaluated with the given refinements activated, so a block written by the caller can
be re-interpreted under the query DSL's refinements:

```ruby
def evaluate_block(&block)
  refined_block = block.refined(ActiveRecord::Refined::BlockSyntax)
  BlockContext.new.instance_exec(&refined_block)
end
```

This is exactly what the old implementation needed and could not do, so the query syntax
works again without monkey-patching `Symbol` globally.

## Requirements

* Ruby 4.1 or later (for `Proc#refined`; not released yet, so a `ruby-master` build is needed for now)
* Active Record 7.0 or later

The [sandbox](https://shugo.github.io/activerecord-refined/) is there to skip
that build: it carries its own Ruby 4.1. `sandbox/` in this repository is what
it is made of.

## Installation

Add this line to your application's Gemfile:

    gem 'activerecord-refined'

And then execute:

    $ bundle

Or install it yourself as:

    $ gem install activerecord-refined

## Usage

Just require the gem, and `where`, `select`, `joins`, `left_outer_joins`, `having`,
`order` and `group` will accept a block.

```ruby
require "activerecord-refined"
```

Inside the block, symbols denote columns of the receiver's table, and `:table[:column]`
denotes a qualified column. That holds in every position — on the right of a
comparison too, so `:age == :retirement_age` compares two columns. A value is
written as its literal, an enum's as its string; a symbol naming no column of
the model is refused rather than compared against nothing anyone meant.

The reference — every method a symbol answers to inside a block, every
function a block can call, and what the relation takes — is on
[rubydoc.info](https://rubydoc.info/gems/activerecord-refined):
[`BlockSyntax`](https://rubydoc.info/gems/activerecord-refined/ActiveRecord/Refined/BlockSyntax)
for the symbol,
[`BlockContext`](https://rubydoc.info/gems/activerecord-refined/ActiveRecord/Refined/BlockContext)
for the block, and
[`QueryMethods`](https://rubydoc.info/gems/activerecord-refined/ActiveRecord/Refined/QueryMethods)
for the relation. What follows is a tour, a topic at a time; each has a page
of its own under [docs/](docs/) that says the rest.

### Conditions

```ruby
Author.where { :age.between?(20, 40) & :name.like?("A%") }
Author.where { :country.in?(%w[JP US]) | :country.null? }
Author.where { !:name.start_with?("A") }
Author.where { :id.in?(Post.select(:author_id)) }               # IN (subquery)
Author.where { exists?(Post.where { :posts[:author_id] == :authors[:id] }) }
```

`&`, `|` and `!` are AND, OR and NOT. A value on the right is quoted as Active
Record quotes it, a column compares against a column, a relation is a
subquery. [docs/conditions.md](docs/conditions.md) has the rest: the
negations SQL spells for itself, `true?` and NULL, regular expressions,
`ANY` and `ALL`, PostgreSQL arrays.

### Joins

```ruby
Author.joins(:posts) { :posts[:author_id] == :authors[:id] }
Employee.joins(:employees, as: :managers) { :managers[:id] == :employees[:manager_id] }
```

`joins`, `left_outer_joins`, `right_outer_joins`, `full_outer_joins` and
`cross_joins` take the `ON` as a block and `as:` for a table alias; a
relation joins as a subquery, and one marked `lateral` as a `LATERAL` one.
[docs/joins.md](docs/joins.md).

### Aggregates and functions

```ruby
Author.group { :country }.having { count(:*) > 1 }
Author.select { [count(:*).filter { :age < 50 }.as(:young), avg(:age).as(:average)] }
Post.group { :author_id }.select { string_agg(:title, ", ").order(:title).as(:titles) }
Post.where { :created_at > current_timestamp - 7.days }
Post.select { cast(:price, "decimal(10,2)").as(:price) }
```

The scalar functions are methods — `upper`, `coalesce`, `round` and the rest
— spelled the adapter's way where the adapters differ, and `fn` reaches any
other by name. [docs/functions.md](docs/functions.md).

### Expressions

```ruby
LineItem.where { :price * :quantity > 1000 }
Post.where { :flags & 4 > 0 }
Author.select { :country.when("JP").then("Japan").else("elsewhere").as(:where) }
Author.select { case_when { :age >= 60 }.then("senior").else("adult").as(:band) }
```

Arithmetic, the bitwise operators and `CASE` are expressions like a column,
so they compare, alias and aggregate. [docs/expressions.md](docs/expressions.md).

### JSON

```ruby
Doc.where { :meta.dig_text(:author, :name) == "alice" }
Doc.where { :meta.key?(:draft) }
Doc.update_all { { meta: :meta.bury(:author, :name, "alice") } }
Post.group { :author_id }.select { json_arrayagg(:title).as(:titles) }
```

`dig` and `dig_text`, `bury`, `except`, `key?` and `keys` read and change a
document by the names Hash uses; `json_object` and `json_arrayagg` build one. The same block
runs on PostgreSQL's `jsonb`, MySQL's JSON and SQLite's.
[docs/json.md](docs/json.md).

### Window functions

```ruby
Author.select { [:name, row_number.over.partition(:country).order(:age.desc).as(:rank)] }
Post.select { sum(:likes).over.order(:created_at).rows(..0).as(:running_total) }
```

`over` on any aggregate or window function, then `partition`, `order`,
`rows` and `range`. [docs/windows.md](docs/windows.md).

### Ordering, aliases and collation

```ruby
Author.order { :country.asc.nulls_last }
Author.select { upper(:name).as(:author) }
Author.where { :name.collate(:nocase) == "alice" }
```

[docs/ordering.md](docs/ordering.md).

### Grouping, CTEs and DISTINCT ON

```ruby
Sale.group { rollup(:region, :product) }
Post.distinct_on { :author_id }.order { [:author_id, :likes.desc] }       # PostgreSQL
Node.with_recursive(tree: [Node.where { :id == 1 }, Node.joins(:tree) { :nodes[:parent_id] == :tree[:id] }]).from_cte(:tree)
```

[docs/grouping.md](docs/grouping.md) and [docs/ctes.md](docs/ctes.md).

### Writing

```ruby
Post.where { :published == true }.update_all { { likes: :likes + 1 } }
Tally.upsert_all(rows, unique_by: :page) { { hits: :hits + excluded(:hits) } }
```

[docs/writing.md](docs/writing.md).

### Time zones

Active Record stores in UTC and a `Time` in a block is quoted the way Active
Record quotes one, so `where { :created_at > Time.current - 1.day }` is right
whatever `Time.zone` is; what the database says the time is —
`current_timestamp`, `extract` — is the session's business.
[docs/time_zones.md](docs/time_zones.md).

## Other adapters

SQLite, PostgreSQL, MySQL, MariaDB, Oracle and SQL Server are built in: each
is a `Dialect`, one class per family of spellings, asked for whatever the
databases write differently. An adapter the gem does not know keeps the
standard spellings, which reach further than you might expect; where they
fall short, a dialect of your own says the rest. Subclass
`ActiveRecord::Refined::Dialect` — or the built-in family the database
descends from — override only what it spells differently, and register it
under the adapter's name:

```ruby
class ExampleDialect < ActiveRecord::Refined::Dialect
  # The example database spells char_length LEN, and has no random ordering.
  FUNCTIONS = { char_length: "LEN", rand: nil }.freeze

  def full_outer_join_supported? = false
end

ActiveRecord::Refined::Dialect.register("exampledb", ExampleDialect)
```

`register` also takes a block for an adapter whose dialect only the
connection can name — the way `mysql2` answers for MySQL and MariaDB both —
receiving the model and returning the class.

## Performance

`benchmark/query_building.rb` compares building the same queries through the
block DSL and through Active Record's other argument styles. Only query
construction (through `to_sql`) is measured — every style produces the same
SQL, so execution costs the same regardless.

Queries built per second (ruby 4.1.0dev, Active Record 8.1.3, one machine —
treat the ratios, not the absolute numbers, as the result):

| query | string | arel | block (this gem) | hash | relation and/or |
| --- | --- | --- | --- | --- | --- |
| simple equality | 42.5k | 42.0k | 37.7k | 31.5k | — |
| range (BETWEEN) | — | 34.6k | 32.7k | 24.8k | — |
| LIKE | 41.5k | 41.0k | 36.8k | — | — |
| compound AND/OR | 34.4k | 27.7k | 24.4k | — | 11.9k |

Allocated memory per built query:

| query | arel | block (this gem) | hash | string | relation and/or |
| --- | --- | --- | --- | --- | --- |
| simple equality | 2,600 B | 2,832 B | 3,328 B | 3,448 B | — |
| compound AND/OR | 3,208 B | 3,584 B | — | 4,680 B | 9,120 B |

In short: the block DSL is 6–13% slower than hand-written Arel (which it
compiles to), a little faster than hash conditions, and both faster and
leaner than `where(...).and(where(...).or(where(...)))` relation chains,
which pay for structural-compatibility checks and relation copies. The
`Proc#refined` call itself costs about 150 ns of the ~25 μs build — the
re-interpretation of the block is not where the time goes. Against a
database round trip of tens to hundreds of microseconds, none of these
differences are visible in an application.

One memory cost sits outside the per-query numbers above: to run a block
under the refinements, `Proc#refined` deep-copies its instruction sequence,
nested blocks included. The copy is made lazily on the refined proc's first
call and memoized per block and refinement list for the life of the process,
so it is paid once per `where { ... }` call site, not per query — the
benchmark measures the copy at the size of the original (568 bytes for the
simple-equality block, 888 bytes for the compound one), and a thousand
further calls from the same call site copy nothing. Steady state, an
application holds one extra copy of each distinct query block's bytecode:
a few hundred bytes per call site. "Per call site" assumes blocks compiled
once, as normal code is — building query blocks with a string `eval` mints
a fresh instruction sequence per pass, each earning a copy of its own, and
the memo keeps both alive for the life of the process.

## Running the tests

The tests only build SQL, but they need a live connection to do it. SQLite is
the default; set `ADAPTER` to run the same suite against another one.

```sh
rake test                    # sqlite3
ADAPTER=postgresql rake test
ADAPTER=mysql2 rake test     # MariaDB
rake test:mysql8             # Oracle's MySQL, on port 3307
rake test:all                # all of the above; MySQL skipped when 3307 is empty
```

PostgreSQL and the MySQLs are reached on `127.0.0.1` as the current user with
no password, which is how the devcontainer sets them up — MariaDB on its own
port and Oracle's MySQL on 3307, since the two answer the `mysql2` adapter
differently and CI runs both. Override with `DB_HOST`, `DB_PORT`,
`DB_USERNAME` and `DB_PASSWORD`. The `activerecord_refined_test` database is
created on first use.

The client gems sit in optional Gemfile groups named after their adapters,
since building each needs its client library installed. A plain bundle
serves SQLite with nothing extra; opt in to the adapters you will reach:

```sh
bundle config set --local with postgresql mysql2 trilogy
```

CI runs one job per adapter with the servers as service containers, Oracle
and SQL Server included — those two have no local server here and run on CI
alone, their clients opted in the same way.

## Releasing

Pushing a `v*` tag runs `.github/workflows/push_gem.yml`, which builds the gem
and publishes it through RubyGems.org's trusted publishing, so no API key is
stored anywhere.

```sh
bundle exec bump patch --tag # or bump {major,minor} etc.
git push --follow-tags
```

## Contributing

1. Fork it
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create new Pull Request
