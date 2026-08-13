# ActiveRecord::Refined

[![gem](https://img.shields.io/gem/v/activerecord-refined.svg)](https://rubygems.org/gems/activerecord-refined)
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

**[Try it in your browser](https://shugo.github.io/activerecord-refined/)** —
Ruby 4.1, ActiveRecord and SQLite run in the page, so the examples build real
SQL and return real rows without a `ruby-master` build of your own.

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
require 'activerecord-refined'
```

Inside the block, symbols denote columns of the receiver's table, and `:table[:column]`
denotes a qualified column.

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

`!` negates any of these. Where SQL has a negative of its own, so does the
block, which is the same rows written the way they would be written by hand:

```ruby
Author.where { :country.not_null? }             # IS NOT NULL
Author.where { :country.not_in?(%w[JP US]) }    # NOT IN
Author.where { :age.not_between?(20, 40) }      # not between 20 and 40
Author.where { :name.not_like?('A%') }          # NOT LIKE
Author.where { :name.not_ilike?('a%') }         # NOT ILIKE / NOT LIKE

Author.where { !:name.start_with?('A') }        # NOT (name LIKE 'A%')
```

Nothing turns on the choice: `NOT (country IS NULL)` and `country IS NOT NULL`
select the same rows, NULLs included. `not_between?` is the one whose SQL
looks unlike its name — Arel writes it as the two comparisons, `age < 20 OR
age > 40`, which is again the same rows.

`in?` also takes a relation as a subquery. Without an explicit select list the
subquery selects the relation's primary key, the same way ActiveRecord's own
`where(id: relation)` does:

```ruby
Author.where { :id.in?(Post.published.select(:author_id)) }
# "authors"."id" IN (SELECT "posts"."author_id" FROM "posts" WHERE ...)
```

A relation on the right of a comparison is a scalar subquery. It has to select
one value, so unlike `in?` there is no default select list and one is
required:

```ruby
Author.where { :age >= Author.select { avg(:age) } }
# "authors"."age" >= (SELECT AVG("authors"."age") FROM "authors")
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
Arel would otherwise reach for `ILIKE`. `ilike?` is the one that asks for
`ILIKE`; off PostgreSQL it is plain `LIKE`, which those adapters already match
case-insensitively under their default collations. `casecmp?` is
case-insensitive equality, folded on both sides rather than left to the
collation, so it means the same thing everywhere:

```ruby
Author.where { :name.ilike?('ma%') }        # ILIKE 'ma%' / LIKE 'ma%'
Author.where { :name.casecmp?('Alice') }     # LOWER(name) = LOWER('Alice')
```

`not_distinct_from?` and `distinct_from?` compare with NULL treated as a
value, rather than as the unknown that makes `=` and `<>` neither true nor
false. PostgreSQL spells this `IS [NOT] DISTINCT FROM`, SQLite `IS` / `IS NOT`
and MySQL `<=>`, and the rows that come back are the same on all three:

```ruby
Author.where { :country.not_distinct_from?(params[:country]) }  # matches NULL to nil
Author.where { :country.distinct_from?('JP') }                  # keeps the NULL rows
```

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

`as` names the table within the query, which is what makes a self join
expressible — the qualified columns in the block go by that name:

```ruby
Employee.joins(:employees, as: :managers) { :managers[:id] == :employees[:manager_id] }
# SELECT "employees".* FROM "employees"
#   INNER JOIN "employees" "managers" ON "managers"."id" = "employees"."manager_id"
```

### Keeping one row per group

`distinct_on` is PostgreSQL's `DISTINCT ON`: the first row of each group the
order brings up.

```ruby
Post.distinct_on { :author_id }.order { [:author_id, :likes.desc] }
# SELECT DISTINCT ON ( "author_id" ) "posts".* FROM "posts"
#   ORDER BY "author_id", "likes" DESC
```

Arel carries the node and refuses to write it for the others, the way it does
a regexp, so it raises `NotImplementedError` on SQLite and MySQL. The shape
that runs everywhere is a `row_number` window in a subquery, which says the
same thing at more length:

```ruby
ranked = Post.select {
  [:author_id, :likes, row_number.over.partition(:author_id).order(:likes.desc).as(:rn)]
}
Post.from(ranked, :posts).where { :rn == 1 }
```

The subquery is named after the model's own table for the reason `from_cte`
is: ActiveRecord goes on qualifying columns with that name, so `where` needs
to find it.

### Common table expressions

ActiveRecord's `with` and `with_recursive` need nothing from this gem: a CTE
is joined by name like any other table, so its `ON` clause is a block, where
Rails' own documentation reaches for a string join.

`from_cte` takes the CTE's name and selects it under the model's own table
name, so the model's columns resolve:

```ruby
Node.with_recursive(
  tree: [
    Node.where { :id == root.id }.
      select { [:id, :name, :parent_id, 0.as(:depth)] },
    Node.joins(:tree) { :nodes[:parent_id] == :tree[:id] }.
      select { [:id, :name, :parent_id, (:tree[:depth] + 1).as(:depth)] },
  ]
).from_cte(:tree)
# WITH RECURSIVE "tree" AS (
#   SELECT "nodes"."id", "nodes"."name", "nodes"."parent_id", 0 AS depth
#     FROM "nodes" WHERE "nodes"."id" = 1
#   UNION ALL
#   SELECT "nodes"."id", "nodes"."name", "nodes"."parent_id",
#          ("tree"."depth" + 1) AS depth
#     FROM "nodes" INNER JOIN "tree" ON "nodes"."parent_id" = "tree"."id"
# ) SELECT "nodes".* FROM "tree" AS "nodes"
```

The anchor starts the count and the recursive member adds one, which is how
the shape of a tree comes out of a flat table. The `0` is a value rather than
SQL — see [`value`](#aggregates-functions-and-aliases) below for why a number
can say `.as` directly.

The alias on the last line is there for ActiveRecord's sake, not SQL's:
written by hand that line would be `SELECT * FROM tree`. ActiveRecord goes on qualifying
columns with the model's table name, so without the alias that name is not in
the query and anything qualifying a column fails:

```ruby
Node.with_recursive(tree: [...]).from(:tree).where(name: 'root')
# PG::UndefinedTable: missing FROM-clause entry for table "nodes"
```

Since the model's name is the only one that works, `from_cte` takes it from
the model rather than asking. `from(:tree, as: :nodes)` is the same thing
spelled out, and is what to reach for when the name wanted is not the model's.

What makes this worth spelling out is how selectively it breaks. `count`,
`order` and `select` never qualify, so they work without the alias on every
adapter; it is `where` and `find_by` that stop. A query can therefore look
right until the day a condition is added to it.

A non-recursive CTE joins the same way:

```ruby
Node.with(roots: Node.where { :parent_id.null? }).
  joins(:roots) { :roots[:id] == :nodes[:parent_id] }
```

`examples/ctes.rb` walks a category tree with these.

### Aggregates and functions

`count`, `sum`, `avg`, `min` and `max` are available as methods, as are the
scalar functions below, with `fn` for anything else. Return an array to select
or order by multiple expressions.

`filter` takes the aggregate over the rows a condition holds for, as a value
or a block:

```ruby
Author.select { count(:*).filter { :age < 50 }.as(:young) }
# COUNT(*) FILTER (WHERE "age" < 50) AS "young"

Author.select {
  [count(:*).as(:all), sum(:age).filter { :country == 'JP' }.as(:jp_years)]
}
```

MySQL has no `FILTER` clause, and gets the case that means the same thing —
`COUNT(CASE WHEN "age" < 50 THEN 1 END)`. An aggregate passes over a NULL, so
a row the condition misses is a row it does not see, and the number that comes
back is the same on all three.

Pass `:*` to `count` for `COUNT(*)`, and `distinct: true` for
`COUNT(DISTINCT ...)`:

```ruby
Author.group { :country }.having { count(:*) > 1 }
# SELECT "authors".* FROM "authors" GROUP BY "authors"."country" HAVING COUNT(*) > 1

Post.select { count(:author_id, distinct: true) }   # COUNT(DISTINCT "author_id")
```

The scalar functions are real methods rather than anything caught dynamically,
so a misspelling is a `NoMethodError` where you wrote it, and a name Ruby also
answers to — `rand` — means the SQL one inside a block:

```
abs  acos  asin  atan  atan2  cast  ceil  char_length  coalesce  concat
cos  current_date  current_time  current_timestamp  date_trunc  degrees
exp  extract  floor  format  greatest  least  length  ln  localtime
localtimestamp  log  log10  log2  lower  ltrim  mod  now  nullif  pi
power  radians  rand  replace  round  rtrim  sign  sin  sqrt  substr  tan
trim  trunc  upper
```

Most are spelled the same everywhere. Where they are not, the method names one
meaning and each adapter gets its own spelling: `char_length`, `greatest` and
`least` become `LENGTH`, `MAX` and `MIN` on SQLite, and `rand` is `RAND` on
MySQL and `RANDOM` elsewhere, and `trunc` is `TRUNCATE` on MySQL, which
insists on the second argument the others default to zero — SQLite's takes
only the one. Where an adapter has no equivalent — `date_trunc` outside
PostgreSQL, `now` and the `local*` pair on SQLite, `log2` on PostgreSQL,
whose spelling is `log(2, x)` — the block raises `NotImplementedError`
rather than leaving the database to reject the SQL.

`format` is printf formatting, and raises on MySQL, where a function of the
same name does something else entirely: it puts separators in a number, and
reads a printf template as the number zero rather than complaining. `fn` still
reaches it, spelled as the different thing it is:

```ruby
Post.select { fn(:format, :amount, 2) }   # MySQL's, on purpose
```

`fn` reaches functions without a method of their own. Its name is emitted as
written, so a case-sensitive one can be spelled exactly:

```ruby
Post.select { fn(:date_trunc, 'day', :created_at).as(:day) }
# SELECT date_trunc('day', "posts"."created_at") AS day
```

Values are quoted by the adapter wherever they appear, as they are in
ActiveRecord, and so is a column alias. That is what makes the name asked for
the name that comes back: unquoted, PostgreSQL folds a capital away where the
other two keep it, so one block would mean two things. It also leaves nothing
to refuse — a name that would have been SQL becomes an identifier with a
strange name instead:

```ruby
Author.select { count(:*).as(:postCount) }       # AS "postCount" everywhere
Author.select { count(:*).as(:'total sales') }   # AS "total sales"
```

`quote: false` asks for the name as written, for a schema that wants the
folding. Nothing quotes it then, so a name that is not plain is refused:

```ruby
Author.select { count(:*).as(:post_count, quote: false) }   # AS post_count
Author.select { count(:*).as(:'total sales', quote: false) }  # ArgumentError
```

`fn`'s function name is the one that cannot be quoted: quoting stops
PostgreSQL folding it, and `"UPPER"(x)` is a function that does not exist.
That one, `cast`'s type and `extract`'s field are neither values nor
identifiers, so they have to be plain names and anything else raises
`ArgumentError` rather than reaching the query.

`current_date`, `current_time`, `current_timestamp`, `localtime` and
`localtimestamp` come out without parentheses, as the grammar has them —
written as calls, PostgreSQL and SQLite would reject them. What does go into
parentheses is an optional precision — `current_timestamp(3)` — which
`current_date` never takes and SQLite never accepts. `current_timestamp` is
the portable spelling of what `now` means, and reaches SQLite where `now`
does not:

```ruby
Post.where { :published_at <= current_timestamp }
# SELECT "posts".* FROM "posts" WHERE "posts"."published_at" <= CURRENT_TIMESTAMP
```

`extract` and `cast` are grammar as well: the field and the type go where no
value could. The field has to be a plain name, and the type has to look like
a type — a plain name, at most parenthesized with lengths, so the adapters'
own spellings like `double precision` or `decimal(10,2)` pass; anything else
raises `ArgumentError`. The type is the adapter's own name for the type, and
whether it exists is the database's to say. SQLite spells everything
`extract` does as `strftime` formats, which no renaming carries, so `extract`
raises there:

```ruby
Post.where { extract(:year, :created_at) == 2026 }
# SELECT "posts".* FROM "posts" WHERE EXTRACT(YEAR FROM "posts"."created_at") = 2026

Post.select { cast(:price, 'decimal(10,2)').as(:price) }
# SELECT CAST("posts"."price" AS decimal(10,2)) AS price
```

### Expressions

`+`, `-`, `*` and `/` build arithmetic. Ruby puts them above the comparison
operators, so an expression groups the way it reads:

```ruby
Item.where { :price * :quantity > 1000 }
Item.select { sum(:price * :quantity).as(:total) }
```

One place asks for a value to be said out loud: the top of a select list.
Everywhere else a bare literal is already a value — `where { :age > 18 }`,
`concat(:name, '-x')` — but ActiveRecord reads a string in `select` as SQL,
so `value` is how you ask for the other meaning. It carries the predications
and arithmetic with it, so a literal can be compared and combined like
anything else. Numbers have a shorthand, since nothing else could be meant by
one:

```ruby
Node.select { [:id, value(0).as(:depth)] }
# SELECT "nodes"."id", 0 AS depth FROM "nodes"

Node.select { [:id, 0.as(:depth)] }         # the same thing

Post.select { [:title, value('draft').as(:state)] }
# SELECT "posts"."title", 'draft' AS state FROM "posts"
```

The shorthand is `Integer` and `Float` only. `String` keeps its two meanings —
SQL in a select list, a value everywhere else — and refining it would make the
same literal mean one thing or the other depending on whether it had been sent
a message.

`CASE` is grammar rather than a function, and has two shapes. With an operand, each `when` is
something to compare it against; without one, each `when` carries a condition
of its own. `case` is a Ruby keyword, so the method behind both is only
reachable through the receiver — `self.case` — and each shape has a shorthand
that does not need it:

```ruby
Author.select { :country.when('JP').then('Japan').else('elsewhere').as(:where) }
# CASE "country" WHEN 'JP' THEN 'Japan' ELSE 'elsewhere' END AS where

Author.select { case_when { :age >= 60 }.then('senior').else('adult').as(:band) }
# CASE WHEN "age" >= 60 THEN 'senior' ELSE 'adult' END AS band

Author.select { self.case(mod(:age, 10)).when(0).then('round').else('not').as(:v) }
```

A `when` takes a value or a block, and so do `then` and `else`; the block is
there to read like the blocks around it, since an argument works just as well
— `:age >= 60` has already become an expression by the time it is passed.
Leaving the `else` off is SQL's own default, which is NULL. `when` and `then`
come in pairs, and one without the other is an `ArgumentError` rather than
something that reaches the database:

```ruby
Author.select {
  case_when { :age < 18 }.then('minor').
    when { :age >= 60 }.then('senior').
    else('adult').as(:band)
}

Author.select { sum(case_when { :age >= 60 }.then(1).else(0)).as(:seniors) }
# SUM(CASE WHEN "age" >= 60 THEN 1 ELSE 0 END) AS seniors
```

### JSON

`dig` reads inside a JSON document, by the name of what `Hash` does. A string
or symbol steps into an object, an integer into an array:

```ruby
Post.where { :meta.dig(:author, :name) == 'alice' }
Post.select { :meta.dig(:tags, 0).as(:first_tag) }
Post.where { :meta.key?(:draft) }
Post.where { :meta.contains?(status: 'open') }
```

No two adapters spell any of this alike, and the block is the same on all
three:

| | PostgreSQL | SQLite | MySQL |
| --- | --- | --- | --- |
| `dig(:a, :b)` | `#>> '{a,b}'` | `->> '$.a.b'` | `JSON_UNQUOTE(JSON_EXTRACT(…, '$.a.b'))` |
| `dig_json(:a)` | `#> '{a}'` | `-> '$.a'` | `JSON_EXTRACT(…, '$.a')` |
| `key?(:a)` | `jsonb_exists(…, 'a')` | `json_type(…, '$.a') IS NOT NULL` | `JSON_CONTAINS_PATH(…, 'one', '$.a')` |
| `contains?(…)` | `@>` | — | `JSON_CONTAINS` |

MariaDB answers to the `mysql2` adapter and has none of `->` or `->>`, so the
MySQL family goes through the functions, which both have.

`dig` gives text everywhere. SQLite's `->>` would otherwise hand back the value
with its type, so a comparison that worked there would fail on the other two;
a number is compared through a `cast` on all three:

```ruby
Post.where { :meta.dig(:n) == '5' }
Post.where { cast(:meta.dig(:n), 'integer') > 6 }   # 'signed' on MySQL
```

The type is the adapter's own name for it, here as everywhere `cast` is used.

`dig_json` keeps the JSON, for a document to be dug into further or compared
whole. `contains?` has no equivalent on SQLite and raises `NotImplementedError`
there — later than the rest, since the adapter is only known when the SQL is
built. On PostgreSQL, `contains?` and `key?` want a `jsonb` column; the
`json` type carries neither operator.

A key that is not a plain name travels as itself rather than being refused:
`dig(:'odd key')` becomes `'{odd key}'` or `$."odd key"`.

### Window functions

`over` gives a function a window, which is what turns an aggregate into a
running one and the only thing `row_number` and its kind can be used with.
The window is built by chaining, as Arel's own is:

```ruby
Author.select { avg(:age).over.partition(:country).as(:country_average) }
# AVG("age") OVER (PARTITION BY "country") AS country_average

Author.select { row_number.over.partition(:country).order(:age.desc).as(:rank) }
# ROW_NUMBER() OVER (PARTITION BY "country" ORDER BY "age" DESC) AS rank

Author.select { count(:*).over.as(:total) }   # COUNT(*) OVER () — every row
```

`row_number`, `rank`, `dense_rank`, `percent_rank`, `cume_dist`, `ntile`,
`lag`, `lead`, `first_value`, `last_value` and `nth_value` are the functions
that say nothing without a window; each raises `ArgumentError` if `over` never
arrives, rather than reaching the database as an error there. Every adapter
that has window functions at all spells them the same way, so unlike the
scalar functions there is nothing here to translate.

A frame is a range of rows counted from the current one — negative before it,
positive after, 0 the row itself, and an open end for unbounded:

```ruby
Post.select { sum(:likes).over.order(:created_at).rows(..0).as(:running) }
# SUM("likes") OVER (ORDER BY "created_at" ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)

Post.select { avg(:likes).over.order(:created_at).rows(-1..1).as(:smoothed) }
# ... ROWS BETWEEN 1 PRECEDING AND 1 FOLLOWING

Post.select { sum(:likes).over.order(:created_at).rows(0..).as(:remaining) }
# ... ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
```

`range` says `RANGE` where `rows` says `ROWS`, and a window has one frame or
none. Named windows — `WINDOW w AS (...)` — have no clause in ActiveRecord to
live in, so they are not here.

### Aliases and ordering

`.as` gives an expression a column alias, and `.asc` / `.desc` give an
ordering its direction. The orderings take `.nulls_first` / `.nulls_last` as
well. MySQL has no such syntax, but Arel emulates it there, so the resulting
order is the same everywhere:

```ruby
Author.order { :country.asc.nulls_last }
```

Together:

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

### Writing

`update_all` reads its hash the way ActiveRecord does — `update_all(likes: :likes)`
sets the column to the symbol itself. The block reads a symbol as the column it
names, as every other block here does, which is what lets the new value be
worked out from the old:

```ruby
Post.where { :published == true }.update_all { { likes: :likes + 1 } }
# UPDATE "posts" SET "likes" = ("posts"."likes" + 1) WHERE ...

Post.update_all { { title: upper(:title), likes: case_when { :likes < 0 }.then(0).else(:likes) } }
```

`upsert_all` takes one too, for the part that decides what happens to a row
that is already there. `excluded` is the row that could not be inserted:

```ruby
Tally.upsert_all(rows, unique_by: :page) { { hits: :hits + excluded(:hits) } }
# ... ON CONFLICT ("page") DO UPDATE SET "hits"=("tallies"."hits" + "excluded"."hits")
```

PostgreSQL and SQLite name that row `excluded`; MySQL spells the same thing
`VALUES(column)`, and the block comes out as whichever the adapter reads.
ActiveRecord's own `on_duplicate:` takes SQL text and nothing else, so this is
the one place the DSL writes SQL out itself rather than handing Arel a tree —
and the two cannot both be given.

`insert_all` has no block: its values are literals by construction.
ActiveRecord type-casts each one on the way into the `VALUES` list, so an
expression does not become SQL there — it becomes nothing, silently. Use
`upsert_all` where a row's value has to be worked out.

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
which is what CI's SQLite job does:

```sh
bundle config set --local without db
```

CI runs all three, one job per adapter, with PostgreSQL and MySQL as service
containers.

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
