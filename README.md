# ActiveRecord::Refined

[![test](https://github.com/shugo/activerecord-refined/actions/workflows/test.yml/badge.svg)](https://github.com/shugo/activerecord-refined/actions/workflows/test.yml)

Adding clean and powerful query syntax on ActiveRecord using refinements.

```ruby
Author.
  joins(:posts) { :posts[:author_id] == :authors[:id] }.
  where { :authors[:age].in?(20..40) & (:posts[:published] == true) }
# SELECT "authors".* FROM "authors"
#   INNER JOIN "posts" ON "posts"."author_id" = "authors"."id"
#   WHERE "authors"."age" BETWEEN 20 AND 40 AND "posts"."published" = TRUE
```

## History

This gem was formerly known as **activerecord-refinements**, created by Akira Matsuda
to experiment with the initial implementation of Ruby 2.0 Refinements. Because of the
Refinements' spec change, that implementation stopped working on Ruby 2.0.0 stable, and
the project was left dormant for a long time.

It has now been renamed to **activerecord-refined** and reimplemented on top of
`Proc#refined`, which will be introduced in Ruby 4.1. `Proc#refined` returns a new proc that
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
* ActiveRecord 7.0 or later

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
require 'activerecord-refined'
```

Inside the block, symbols denote columns of the receiver's table, and `:table[:column]`
denotes a qualified column.

### Design policy

The name of an expression decides what it means; a type — of the value, the
column, or the adapter — only ever decides how that one meaning is spelled.
`in?` means "belongs to this set" whether the set is a Range (`BETWEEN`), a
list (`IN`) or a relation (`IN (SELECT ...)`), and `=~` matches a regexp
whether the adapter spells that `REGEXP` or `~` — one meaning, several
spellings. What a type may never change is the meaning itself: `like?` stays
case-sensitive `LIKE` rather than following Arel into `ILIKE`, substring
`include?` and element `member?` are two methods instead of one that inspects
the column type, and `== nil` raises instead of quietly becoming `IS NULL`,
because each of those is a different meaning, and a different meaning
deserves a different name.

### Conditions

```ruby
Author.where { :age >= 18 }
Author.where { :name.like?('A%') }          # LIKE
Author.where { :age.in?(20..40) }           # BETWEEN
Author.where { :age.between?(20, 40) }      # BETWEEN
Author.where { :age.in?(18..) }             # >= 18
Author.where { :country.in?(%w[JP US]) }    # IN
Author.where { :country.null? }             # IS NULL
```

`in?` also takes a relation as a subquery. Without an explicit select list the
subquery selects the relation's primary key, the same way ActiveRecord's own
`where(id: relation)` does:

```ruby
Author.where { :id.in?(Post.published.select(:author_id)) }
# "authors"."id" IN (SELECT "posts"."author_id" FROM "posts" WHERE ...)
```

`exists?` takes a relation and becomes `EXISTS (SELECT ...)`. Correlate the
subquery with the outer table through qualified columns — its `where` block
goes through the DSL like any other:

```ruby
Author.where { exists?(Post.where { :posts[:author_id] == :authors[:id] }) }
# EXISTS (SELECT "posts".* FROM "posts" WHERE "posts"."author_id" = "authors"."id")

Author.where { !exists?(Post.where { :posts[:author_id] == :authors[:id] }) }
# NOT (EXISTS (...))
```

`like?` is case-sensitive `LIKE` on every adapter, including PostgreSQL, where
Arel would otherwise reach for `ILIKE`.

`start_with?`, `end_with?` and `include?` are shortcuts for the usual `like?`
patterns. Unlike `like?`, they treat their argument as a literal string, so `%`
and `_` in it are escaped rather than matched as wildcards:

```ruby
Author.where { :name.start_with?('A') }     # LIKE 'A%'
Author.where { :name.end_with?('son') }     # LIKE '%son'
Author.where { :name.include?('test') }     # LIKE '%test%'
```

Like their String namesakes, `start_with?` and `end_with?` take any number of
literals; matching any one of them is enough:

```ruby
Author.where { :name.start_with?('A', 'B') }
# (name LIKE 'A%' OR name LIKE 'B%')
```

`member?`, `superset?`, `subset?` and `intersect?` compare against a
PostgreSQL array column, each carrying the meaning of its Ruby namesake:
`member?` is Enumerable's element test (which String does not have — that is
what separates it from `include?`), `superset?` and `subset?` are Set's
whole-array containment, and `intersect?` is Array's "any element in common":

```ruby
Article.where { :tags.member?('ruby') }            # tags @> '{ruby}'
Article.where { :scores.member?(80) }              # scores @> '{80}'
Article.where { :tags.superset?(%w[ruby rails]) }  # tags @> '{ruby,rails}'
Article.where { :tags.subset?(%w[ruby rails go]) } # tags <@ '{ruby,rails,go}'
Article.where { :tags.intersect?(%w[ruby go]) }    # tags && '{ruby,go}'
```

Like its namesake, `member?` takes one element — `[1, 2].member?([1])` is
false in Ruby, so an Array argument raises rather than quietly meaning
something `Array#member?` does not. Requiring every element is `superset?`.

`=~` and `!~` match a regular expression: `REGEXP` and `NOT REGEXP` on MySQL,
`~` and `!~` on PostgreSQL. SQLite has no regexp operator of its own, so it
raises there.

```ruby
Author.where { :name =~ '^A' }              # REGEXP / ~
Author.where { :name !~ '^A' }              # NOT REGEXP / !~
Author.where { :name =~ /son$/ }            # a Regexp literal works too
```

Only a literal's source crosses over; the database has its own dialect and no
equivalent of Ruby's flags. Dropping one would silently change what the query
matches, so `/son$/i` raises instead — pass the pattern as a string if the
database can express what you mean.

`==` always means SQL `=`, and passes its value through untouched. A Range or an
Array therefore compares against a PostgreSQL range or array column, the same
way ActiveRecord's own `where(period: from...to)` does for those column types:

```ruby
Reservation.where { :period == (from...to) }   # daterange = '[from,to)'
Article.where { :tags == %w[ruby rails] }      # text[] = '{ruby,rails}'
```

`!=` is SQL `!=` under the same rules, value passed through untouched.

For the same reason `== nil` and `!= nil` raise `ArgumentError`: `= NULL` is
never true in SQL, so a NULL test has to be spelled as one. Use `null?`:

```ruby
Author.where { :country.null? }             # country IS NULL
Author.where { !:country.null? }            # NOT (country IS NULL)
```

Combine predicates with `&`, `|` and `!`. Ruby's operator precedence makes the
parentheses around each comparison necessary, though the `?` methods above need
none:

```ruby
Author.where { (:age >= 18) & ((:country == 'JP') | (:country == 'US')) }
Author.where { !(:age.in?(0..17) | :country.null?) }
Author.where { !:country.in?(%w[JP US]) }   # NOT (country IN ('JP', 'US'))
Author.where { !:name.like?('%test%') }     # NOT (name LIKE '%test%')
```

### Joins

The block is the `ON` clause:

```ruby
Author.
  joins(:posts) { :posts[:author_id] == :authors[:id] }.
  joins(:comments) { :comments[:post_id] == :posts[:id] }

Author.left_outer_joins(:posts) { :posts[:author_id] == :authors[:id] }
```

### Aggregates, functions and aliases

`count`, `sum`, `avg`, `min` and `max` are available as methods, as are the scalar
functions `upper`, `lower`, `length`, `trim`, `coalesce`, `abs` and `round`. Use `.as`
for a column alias, and `.asc` / `.desc` for the sort direction. Return an array to
select or order by multiple expressions.

Pass `:*` to `count` for `COUNT(*)`:

```ruby
Author.group { :country }.having { count(:*) > 1 }
# SELECT "authors".* FROM "authors" GROUP BY "authors"."country" HAVING COUNT(*) > 1
```

```ruby
Author.
  joins(:posts) { :posts[:author_id] == :authors[:id] }.
  where { :posts[:published] == true }.
  group { :authors[:id] }.
  having { count(:posts[:id]) > 1 }.
  order { count(:posts[:id]).desc }.
  select {
    [
      upper(:authors[:name]).as(:author),
      count(:posts[:id]).as(:post_count),
      avg(:posts[:likes]).as(:avg_likes),
    ]
  }
```

See `examples/` for complete, runnable scripts.

## Performance

`benchmark/query_building.rb` compares building the same queries through the
block DSL and through ActiveRecord's other argument styles. Only query
construction (through `to_sql`) is measured — every style produces the same
SQL, so execution costs the same regardless.

Queries built per second (ruby 4.1.0dev, ActiveRecord 8.1.3, one machine —
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
ADAPTER=mysql2 rake test
rake test:all                # all three in turn
```

PostgreSQL and MySQL are reached on `127.0.0.1` as the current user with no
password, which is how the devcontainer sets them up. Override with
`DB_HOST`, `DB_USERNAME` and `DB_PASSWORD`. The `activerecord_refined_test`
database is created on first use.

The `pg` and `mysql2` gems are in the Gemfile's `db` group, since building them
needs the client libraries installed. Skip them if SQLite is all you need,
which is what CI does:

```sh
bundle config set --local without db
```

## Releasing

Pushing a `v*` tag runs `.github/workflows/push_gem.yml`, which builds the gem
and publishes it through RubyGems.org's trusted publishing, so no API key is
stored anywhere.

```sh
bump patch --tag # or bump {major,minor} etc.
git push --follow-tags
```

## Contributing

1. Fork it
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create new Pull Request
