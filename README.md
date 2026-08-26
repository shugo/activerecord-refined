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

### Conditions

```ruby
Author.where { :age >= 18 }
Author.where { :name.like?("A%") }          # LIKE
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
Author.where { :name.not_like?("A%") }          # NOT LIKE
Author.where { :name.not_ilike?("a%") }         # NOT ILIKE / NOT LIKE

Author.where { !:name.start_with?("A") }        # NOT (name LIKE 'A%')
```

Nothing turns on the choice: `NOT (country IS NULL)` and `country IS NOT NULL`
select the same rows, NULLs included. `not_between?` is the one whose SQL
looks unlike its name — Arel writes it as the two comparisons, `age < 20 OR
age > 40`, which is again the same rows.

A number compares as itself, the way a bound `?` does: `:age >= 99.5` says
`>= 99.5`, where `where(age: 99.5..)` casts to the column's type and says
`>= 99`, letting an age of 99 through a bound it does not satisfy. Everything
that is not an `Integer`, `Float` or `BigDecimal` keeps the column's own
serialization — an enum's name, a time's zone, a custom type's scaling — so a
custom type that scales a number, money kept in cents, is the one place the
number has to be written as the column stores it.

A boolean column has `true?` and `false?`, which become SQL's `IS TRUE` and
`IS FALSE`, and the two negations to go with them:

```ruby
Post.where { :published.true? }         # IS TRUE
Post.where { :published.not_true? }     # IS NOT TRUE
Post.where { :published.false? }        # IS FALSE
Post.where { :published.not_false? }    # IS NOT FALSE
```

`published = TRUE` selects the same rows as `published IS TRUE`, so the
difference is in the negation: `published = TRUE` is itself NULL for a row
where the column is, and a NULL predicate selects nothing, while `IS TRUE`
answers false there. `not_true?` is therefore "false or never set" and
`!(:published == true)` only "false". Every adapter spells all four the same
way and answers them alike.

`in?` also takes a relation as a subquery. Without an explicit select list the
subquery selects the relation's primary key, the same way Active Record's own
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

`any` and `all` quantify that comparison instead, which is what lifts the
one-row rule: `> any` asks whether the subquery holds a smaller value anywhere,
`>= all` whether it holds a larger one nowhere.

```ruby
Author.where { :age > any(Author.where(country: "JP").select(:age)) }
# "authors"."age" > ANY(SELECT "authors"."age" FROM "authors" WHERE ...)

Author.where { :age >= all(Author.select(:age)) }
# "authors"."age" >= ALL(SELECT "authors"."age" FROM "authors")
```

The select list follows `in?`'s rule rather than the scalar one: without an
explicit select the subquery selects the primary key. `== any` is what `IN`
says and `!= all` what `NOT IN` says, so what the quantifiers add is the four
comparisons `IN` has no spelling for. SQLite has neither quantifier, and says
so with `NotImplementedError` rather than leaving its parser to.

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
Author.where { :name.ilike?("ma%") }        # ILIKE 'ma%' / LIKE 'ma%'
Author.where { :name.casecmp?("Alice") }     # LOWER(name) = LOWER('Alice')
```

`not_distinct_from?` and `distinct_from?` compare with NULL treated as a
value, rather than as the unknown that makes `=` and `<>` neither true nor
false. PostgreSQL spells this `IS [NOT] DISTINCT FROM`, SQLite `IS` / `IS NOT`
and MySQL `<=>`, and the rows that come back are the same on all three:

```ruby
Author.where { :country.not_distinct_from?(params[:country]) }  # matches NULL to nil
Author.where { :country.distinct_from?("JP") }                  # keeps the NULL rows
```

`start_with?`, `end_with?` and `include?` are shortcuts for the usual `like?`
patterns. Unlike `like?`, they treat their argument as a literal string, so `%`
and `_` in it are escaped rather than matched as wildcards:

```ruby
Author.where { :name.start_with?("A") }     # LIKE 'A%'
Author.where { :name.end_with?("son") }     # LIKE '%son'
Author.where { :name.include?("test") }     # LIKE '%test%'
```

Like their String namesakes, `start_with?` and `end_with?` take any number of
literals; matching any one of them is enough:

```ruby
Author.where { :name.start_with?("A", "B") }
# (name LIKE 'A%' OR name LIKE 'B%')
```

`member?`, `superset?`, `subset?` and `intersect?` compare against a
PostgreSQL array column, each carrying the meaning of its Ruby namesake:
`member?` is Enumerable's element test (which String does not have — that is
what separates it from `include?`), `superset?` and `subset?` are Set's
whole-array containment, and `intersect?` is Array's "any element in common":

```ruby
Article.where { :tags.member?("ruby") }            # tags @> '{ruby}'
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
Author.where { :name =~ "^A" }              # REGEXP / ~
Author.where { :name !~ "^A" }              # NOT REGEXP / !~
Author.where { :name =~ /son$/ }            # a Regexp literal works too
```

Only a literal's source crosses over; the database has its own dialect and no
equivalent of Ruby's flags. Dropping one would silently change what the query
matches, so `/son$/i` raises instead — pass the pattern as a string if the
database can express what you mean.

`==` always means SQL `=`, and passes its value through untouched. A Range or an
Array therefore compares against a PostgreSQL range or array column, the same
way Active Record's own `where(period: from...to)` does for those column types:

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
Author.where { (:age >= 18) & ((:country == "JP") | (:country == "US")) }
Author.where { !(:age.in?(0..17) | :country.null?) }
Author.where { !:country.in?(%w[JP US]) }   # NOT (country IN ('JP', 'US'))
Author.where { !:name.like?("%test%") }     # NOT (name LIKE '%test%')
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

`right_outer_joins` and `full_outer_joins` are the two Active Record has no
method for, and they take what `joins` takes. An association name is not among
it: what Active Record reads out of one is an inner or a left join and nothing
else, so these two want the block that says how to join.

```ruby
Author.right_outer_joins(:posts) { :posts[:author_id] == :authors[:id] }
Author.full_outer_joins(:posts) { :posts[:author_id] == :authors[:id] }
```

MySQL has no `FULL OUTER JOIN` and neither has MariaDB, so `full_outer_joins`
raises `NotImplementedError` there. SQLite has had one since 3.39.

`cross_joins` is every row of one table against every row of the other. There
is no condition to give, so it takes no block — `as` still names the table:

```ruby
Post.cross_joins(:authors)              # FROM "posts" CROSS JOIN "authors"
Post.cross_joins(:posts, as: :others)   # FROM "posts" CROSS JOIN "posts" "others"
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
is: Active Record goes on qualifying columns with that name, so `where` needs
to find it.

### Grouping several ways at once

`grouping_sets`, `rollup` and `cube` ask for more than one grouping in a
single query, the totals of each coming back beside the rows. Each set is a
list of its own, and an empty one is the grand total:

```ruby
Sale.group { grouping_sets([:region], [:product], []) }.
  select { [:region, :product, sum(:amount).as(:total)] }
# GROUP BY GROUPING SETS( ( "region" ), ( "product" ), (  ) )

Sale.group { rollup(:region, :product) }   # GROUP BY ROLLUP( "region", "product" )
Sale.group { cube(:region, :product) }     # GROUP BY CUBE( "region", "product" )
```

A row that a set did not group by comes back with NULL there, which is also
what a real NULL looks like; `fn(:grouping, :region)` tells the two apart.

`grouping_sets` and `cube` are PostgreSQL's; SQLite has none of the three and
both raise `NotImplementedError` elsewhere. `rollup` runs on MySQL and
MariaDB too, spelled as their `WITH ROLLUP` — which trails the whole group
list, so there a rollup cannot stand beside other group entries the way
`ROLLUP(...)` can, and the block says so. MariaDB is also the one that
refuses `ORDER BY` next to it, and the one without `fn(:grouping, ...)`.

### Lateral joins

A relation marked `lateral` joins in place of a table, and sees the row being
joined to — in SQL the keyword modifies the subquery, not the join, so that is
where it is written. It is what makes the top row of each group reachable in
one query:

```ruby
top_post = Post.select { :title }.
  where { :posts[:author_id] == :authors[:id] }.
  order { :likes.desc }.limit(1)

Author.left_outer_joins(top_post.lateral, as: :top).
  select { [:name, :top[:title].as(:top_post)] }
# SELECT "name", "top"."title" AS "top_post" FROM "authors"
#   LEFT OUTER JOIN LATERAL (SELECT "title" FROM "posts"
#     WHERE "posts"."author_id" = "authors"."id" ORDER BY "likes" DESC LIMIT 1) "top" ON TRUE
```

`as` is required — the relation has no name of its own to qualify with. Without
a block the join is `ON TRUE`, which is the usual shape: what the subquery is
allowed to see is said inside it. A block writes a real `ON` clause.

PostgreSQL has `LATERAL` and so has MySQL, from 8.0.14. SQLite has none, and
neither has MariaDB, which answers to the same adapter as MySQL; both raise
`NotImplementedError`. Arel has a node for it but only PostgreSQL's visitor
writes it, so the SQL is written here instead.

### Common table expressions

Active Record's `with` and `with_recursive` need nothing from this gem: a CTE
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

The alias on the last line is there for Active Record's sake, not SQL's:
written by hand that line would be `SELECT * FROM tree`. Active Record goes on qualifying
columns with the model's table name, so without the alias that name is not in
the query and anything qualifying a column fails:

```ruby
Node.with_recursive(tree: [...]).from(:tree).where(name: 'root')
# PG::UndefinedTable: missing FROM-clause entry for table "nodes"
```

Since the model's name is the only one that works, `from_cte` takes it from
the model rather than asking. It also checks that the name is one `with`
declares, so a typo is an `ArgumentError` here rather than a query against a
table nobody has — checked when the SQL is built, so the CTE may be declared
later in the chain or by a scope merged into it.

`from(:tree, as: :nodes)` is the same thing spelled out, without the check,
and is what to reach for when the name wanted is not the model's.

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
bit aggregates and the scalar functions below, with `fn` for anything else. Return an array to select
or order by multiple expressions.

`filter` takes the aggregate over the rows a condition holds for, as a value
or a block:

```ruby
Author.select { count(:*).filter { :age < 50 }.as(:young) }
# COUNT(*) FILTER (WHERE "age" < 50) AS "young"

Author.select {
  [count(:*).as(:all), sum(:age).filter { :country == "JP" }.as(:jp_years)]
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
abs  acos  asin  atan  atan2  bit_and  bit_count  bit_or  bit_xor  cast
ceil  char_length  coalesce  concat
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
whose spelling is `log(2, x)`, the four `bit_*` on SQLite — the block raises
`NotImplementedError` rather than leaving the database to reject the SQL.

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
Post.select { fn(:date_trunc, "day", :created_at).as(:day) }
# SELECT date_trunc('day', "posts"."created_at") AS day
```

`op` is the same escape hatch for operators — PostgreSQL alone has dozens
with no method here, `<@` and `&&` and the geometric ones among them. The
operator is emitted as written and, like `fn`'s names, whether the adapter
has it is your assertion; it is checked against the characters PostgreSQL
allows an operator, so a letter, a space or a quote is refused rather than
written into the SQL. Both sides take what `fn`'s arguments take — a
column, an expression, a value quoted by the adapter — and a value is
spelled in the adapter's own syntax, `to_json` saying a document, `'{a,b}'`
an array; a Ruby Hash or Array is refused rather than guessed at. The
result is parenthesized, its precedence being unknown, and so is an
expression on either side, so a dug value cannot be re-grouped out from
under it:

```ruby
Post.where { op("&&", :tags, "{ruby,sql}") }
# WHERE ("posts"."tags" && '{ruby,sql}')

Post.where { op("<@", :meta.dig(:author), { name: "alice" }.to_json) }
# WHERE (("meta" #> '{author}') <@ '{"name":"alice"}')
```

`sql` is the last resort, for what neither `fn` nor `op` can spell: the
statement goes out as written. It is the one way a string means SQL inside a
block — everywhere else a string is a value — so writing SQL is always asked
for by name, and an interpolation has a spelling that is not it: `?` and
`:name` placeholders take values quoted by the adapter, through
`sanitize_sql_array`. A `?` is rewritten only when there are positional binds
to put in it, so PostgreSQL's `?` operators can share a statement with named
binds, or with none. The result carries the predications and arithmetic, and
is parenthesized where it stands inside a larger expression — its precedence
is whatever was written — but comes out bare at the top of a select list,
where parentheses would refuse an alias written into the string:

```ruby
Post.where { sql("length(title) > ?", 10) }
# WHERE (length(title) > 10)

Post.where { sql("score + ?", 10) * 2 >= 60 }
# WHERE (score + 10) * 2 >= 60

Post.select { sql("count(*) FILTER (WHERE score > 0) AS positive") }
```

Values are quoted by the adapter wherever they appear, as they are in
Active Record, and so is a column alias. That is what makes the name asked for
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

Post.select { cast(:price, "decimal(10,2)").as(:price) }
# SELECT CAST("posts"."price" AS decimal(10,2)) AS price
```

### Expressions

`+`, `-`, `*` and `/` build arithmetic. Ruby puts them above the comparison
operators, so an expression groups the way it reads:

```ruby
Item.where { :price * :quantity > 1000 }
Item.select { sum(:price * :quantity).as(:total) }
```

The number may stand on the left — only a column or an expression on the
right builds a query, so Ruby's own arithmetic is untouched — and
`BigDecimal` is a number here, being what a decimal column's values are,
quoted as the exact decimal on either side. A `Rational` is refused: no
decimal spells `1/3r` exactly, and `to_d` is what says the decimal meant.

```ruby
Item.select { greatest(20 - :quantity, 0).as(:shortfall) }
Item.where { BigDecimal("1.08") * :price > 500 }
```

`&`, `|`, `^`, `~`, `<<` and `>>` are SQL's bitwise operators. Between
conditions `&` and `|` are AND and OR, and that is where they are defined,
which leaves them free to mean here what SQL means by them:

```ruby
Post.where { :flags & 4 > 0 }
# WHERE ("posts"."flags" & 4) > 0

Post.select { (:flags | 4).as(:flags) }
Post.select { (~:flags).as(:inverted) }
```

Each parenthesises itself, which is what keeps Ruby's grouping: PostgreSQL
gives `&` and `|` the same precedence and reads `a | b & c` from the left,
where Ruby reads the `&` first.

A boolean column is refused rather than taken for the one bit it is stored as.
MySQL and SQLite would quietly answer as `AND` would, PostgreSQL has no such
operator at all, and one block meaning two things is worse than an
`ArgumentError` saying that `true?` is what makes a boolean column a
condition. A condition as an operand is refused for the same reason.

XOR is the one the three do not share, and the one where guessing costs most:
MySQL spells it `^`, which is exponentiation to PostgreSQL, and PostgreSQL
spells it `#`, which is where a comment starts on MySQL — either way a wrong
answer rather than an error. Each adapter gets its own, and SQLite, which has
no XOR at all, gets the two operations it is made of, `(a | b) - (a & b)`.
That names each operand twice, so keep them cheap.

`bit_and`, `bit_or` and `bit_xor` are the aggregates of the first three, and
`bit_count` counts the bits that are set. SQLite has none of the four.
PostgreSQL counts the bits of a bit string rather than of a number, so the
argument is cast there, to `bit(64)` because that is what makes a negative
count as it does on MySQL:

```ruby
Post.group { :author_id }.select { bit_or(:flags).as(:flags) }
# SELECT BIT_OR("posts"."flags") AS "flags" ... GROUP BY "posts"."author_id"

Post.select { bit_count(:flags).as(:bits) }
# MySQL:      BIT_COUNT("posts"."flags")
# PostgreSQL: BIT_COUNT(CAST("posts"."flags" AS bit(64)))
```

`bit_xor` arrived in PostgreSQL 14. `~` is where the three disagree about the
answer rather than the question: MySQL reads it back as the unsigned 64-bit
number, the others as a negative one, and the bits are the same either way.

One place asks for a value to be said out loud: the top of a select list.
Everywhere else a bare literal is already a value — `where { :age > 18 }`,
`concat(:name, '-x')` — but a bare string at the top of the list would be SQL
to Active Record and a value everywhere else in the block, so it is refused
rather than read either way: `sql` says the SQL, `value` the value. `value`
carries the predications and arithmetic with it, so a literal can be compared
and combined like anything else, and numbers and strings have a shorthand,
since a literal that has been sent `as` has already said it is a value:

```ruby
Node.select { [:id, value(0).as(:depth)] }
# SELECT "nodes"."id", 0 AS depth FROM "nodes"

Node.select { [:id, 0.as(:depth)] }         # the same thing

Post.select { [:title, "draft".as(:state)] }
# SELECT "posts"."title", 'draft' AS state FROM "posts"
```

What the shorthand does not cover, `value` still spells: `value(true)`,
`value(nil)`, or a literal that goes on to be compared rather than selected.

`CASE` is grammar rather than a function, and has two shapes. With an operand, each `when` is
something to compare it against; without one, each `when` carries a condition
of its own. `case` is a Ruby keyword, so the method behind both is only
reachable through the receiver — `self.case` — and each shape has a shorthand
that does not need it:

```ruby
Author.select { :country.when("JP").then("Japan").else("elsewhere").as(:where) }
# CASE "country" WHEN 'JP' THEN 'Japan' ELSE 'elsewhere' END AS where

Author.select { case_when { :age >= 60 }.then("senior").else("adult").as(:band) }
# CASE WHEN "age" >= 60 THEN 'senior' ELSE 'adult' END AS band

Author.select { self.case(mod(:age, 10)).when(0).then("round").else("not").as(:v) }
```

A `when` takes a value or a block, and so do `then` and `else`; the block is
there to read like the blocks around it, since an argument works just as well
— `:age >= 60` has already become an expression by the time it is passed.
Leaving the `else` off is SQL's own default, which is NULL. `when` and `then`
come in pairs, and one without the other is an `ArgumentError` rather than
something that reaches the database:

```ruby
Author.select {
  case_when { :age < 18 }.then("minor").
    when { :age >= 60 }.then("senior").
    else("adult").as(:band)
}

Author.select { sum(case_when { :age >= 60 }.then(1).else(0)).as(:seniors) }
# SUM(CASE WHEN "age" >= 60 THEN 1 ELSE 0 END) AS seniors
```

### JSON

`dig` reads inside a JSON document, by the name of what `Hash` does. A string
or symbol steps into an object, an integer into an array, and what comes back
is still JSON — the way `Hash#dig` hands back the structure itself — for a
document to be dug into further or asked the JSON questions. `dig_text` gives
the value as text instead, which is what a comparison wants:

```ruby
Post.where { :meta.dig_text(:author, :name) == "alice" }
Post.select { :meta.dig(:author).as(:author) }
Post.where { :meta.key?(:draft) }
Post.where { :meta.contains?(status: "open") }
```

No two adapters spell any of this alike, and the block is the same on all
three:

| | PostgreSQL | SQLite | MySQL |
| --- | --- | --- | --- |
| `dig(:a, :b)` | `#> '{a,b}'` | `-> '$.a.b'` | `JSON_EXTRACT(…, '$.a.b')` |
| `dig_text(:a, :b)` | `#>> '{a,b}'` | `->> '$.a.b'` | `JSON_UNQUOTE(JSON_EXTRACT(…, '$.a.b'))` |
| `key?(:a)` | `? 'a'` | `json_type(…, '$.a') IS NOT NULL` | `JSON_CONTAINS_PATH(…, 'one', '$.a')` |
| `contains?(…)` | `@>` | — | `JSON_CONTAINS` |

MariaDB answers to the `mysql2` adapter and has none of `->` or `->>`, so the
MySQL family goes through the functions, which both have.

`dig_text` gives text everywhere. SQLite's `->>` would otherwise hand back the
value with its type, so a comparison that worked there would fail on the other
two; a number is compared through a `cast` on all three:

```ruby
Post.where { :meta.dig_text(:n) == "5" }
Post.where { cast(:meta.dig_text(:n), "integer") > 6 }   # 'signed' on MySQL
```

The type is the adapter's own name for it, here as everywhere `cast` is used.

Strings and numbers are where the adapters agree. A JSON boolean comes back as
`"1"` on SQLite, which turns `true` into SQL's `1` before the text cast, and
as `"true"` on the other two; a JSON `null` is SQL `NULL` everywhere but
MariaDB, which spells it `"null"`. A key that is not there is `NULL` on all
three.

Comparing `dig_text`'s value with anything but a string raises
`ArgumentError` rather than being left to the adapters, which answer it three
ways: `dig_text(:n) == 5` is true on SQLite, an error on PostgreSQL and true
on MySQL, and `dig_text(:flag) == true` is true, an error and false. `cast`
is what says which type was meant, and then all three agree.

A JSON comparison — `dig`'s side, and `bury`'s and `except`'s — belongs to
the JSON types: on PostgreSQL's `jsonb` and MySQL's `JSON` alike, numbers
compare as numbers and documents structurally, key order and spelling aside,
so a dug value compares with a Ruby one directly. SQLite and MariaDB have
only the text of each, which is a different question, and raise
`NotImplementedError` as the SQL is written. `in?` and `between?` are the
two MySQL leaves out of its JSON comparisons, so there they are spelled as
the comparisons they mean — the range as its bounds, the list as one
equality per element, which names the dug value once per element the way
SQLite's XOR names its operands twice:

```ruby
Post.where { :meta.dig(:stars) >= 10 }              # PostgreSQL and MySQL
Post.where { :meta.dig(:author) == { "name" => "alice" } }
Post.where { :meta.dig(:stars).in?([5, 10]) }
Post.where { cast(:meta.dig_text(:stars), "integer") >= 10 }   # everywhere
```

A column, a function or another dug value on the right goes through untouched
on every adapter. Arithmetic and the bit operators are refused outright on
both sides — `dig_text(:n) + 1` is 6 on SQLite, an error on PostgreSQL and
6.0 on MariaDB — and `cast` settles those too.

`bury` sets what `dig` reads: the last argument is the value and the rest are
the path to it. The document comes back changed rather than being written
anywhere, so `update_all` is what makes it stick:

```ruby
Post.update_all { { meta: :meta.bury(:author, :name, "alice") } }
# SET "meta" = jsonb_set("meta", '{author,name}', '"alice"')
# ...          JSON_SET("meta", '$.author.name', 'alice')   elsewhere

Post.update_all { { meta: :meta.bury(:tags, ["ruby", "sql"]) } }
Post.update_all { { meta: :meta.bury(:copy, :meta.dig(:n)) } }
```

A whole document goes in as one — an object or an array rather than the string
that spells it — which each adapter takes its own way round, and a boolean
goes in as JSON too, which SQLite would otherwise write as its `1`. `bury` is
not a Ruby method; it is the name Ruby considered for the other end of `dig`,
and
SQL has no one name to borrow here, since PostgreSQL says `jsonb_set` where
the others say `JSON_SET`.

`except` takes keys out again, and takes them as `Hash#except` does — keys of
the document, however many, rather than a path, which is `bury`'s way of
reaching further in. It gives back the document changed, so it chains with
`bury` and goes where `bury` goes:

```ruby
Post.update_all { { meta: :meta.except(:draft) } }
# SET "meta" = "meta" - CAST('{"draft"}' AS text[])
# ...          JSON_REMOVE("meta", '$.draft')   elsewhere

Post.update_all { { meta: :meta.bury(:author, :name, "alice").except(:tmp) } }
```

A key that is not there is not an error, as it is not to `Hash#except`. The
cast is not decoration: `jsonb` has three subtractions — a key, an array of
keys, an element by index — and an array literal written without a type is
read as the first of them, so `"meta" - '{draft}'` takes out the key spelled
`{draft}`, which is nothing, and says nothing about it.

A key deeper in is reached through the chain: `dig` reads the part out,
`except` takes the key from it, and `bury` puts it back:

```ruby
Post.update_all { { meta: :meta.bury(:author, :meta.dig(:author).except(:email)) } }
```

What `dig` gives is a document, so the JSON operations read it — the same
question asked of a part of the document rather than of all of it:

```ruby
Post.where { :meta.dig(:author).key?(:email) }
Post.where { :meta.dig(:author).dig_text(:name) == "alice" }
Post.update_all { { meta: :meta.dig(:author).bury(:name, "alice") } }
```

Containment reads it too, on the adapters that have containment at all:

```ruby
Post.where { :meta.dig(:tags).contains?(["ruby"]) }
```

Asking the same of `dig_text` raises `ArgumentError`: what it gives is text,
and reading text back as a document is where the adapters part company —
SQLite parses it, MySQL takes it as written, and PostgreSQL has no such
function for text at all.

`contains?` has no equivalent on SQLite and raises `NotImplementedError`
there — later than the rest, since the adapter is only known when the SQL is
built. On PostgreSQL, `dig` and `dig_text` are all the `json` type carries;
`key?`, `contains?`, `bury` and `except` want a `jsonb` column.

A key that is not a plain name travels as itself rather than being refused:
`dig(:'odd key')` becomes `'{odd key}'` or `$."odd key"`.

`keys` gives the keys of the document, as `Hash#keys` does — a JSON array
of them. Only the MySQL family has a function for it; the other two reach
the same array through a subquery over their key-listing functions, guarded
by type so that all four answer alike: the keys of anything that is not an
object are `NULL` — rather than SQLite's array indices or PostgreSQL's
error — and the keys of `{}` are `[]` rather than PostgreSQL's `NULL`:

```ruby
Post.select { :meta.keys.as(:fields) }
Post.select { :meta.dig(:author).keys.as(:author_fields) }
# JSON_KEYS("meta")                                              MySQL
# CASE WHEN jsonb_typeof("meta") = 'object' THEN COALESCE((…))   PostgreSQL
# CASE WHEN json_type("meta") = 'object' THEN (SELECT …)         SQLite
```

The order the keys come in is the adapters' own: the JSON types give their
normalized order and the text ones the stored order — the same divide every
JSON comparison here rides on.

`json_array` and `json_object` build a document in the row — `json_array`
from the values given, `json_object` from a Ruby hash. The names are the
standard's, which SQLite and the MySQL family say as written; PostgreSQL is
asked to build `jsonb`. A hash rather than SQL's alternating keys and
values, because a bare symbol means a column in every block here: the keys
are Ruby's and the values are expressions, so `title: :title` reads the
column in under its own name with no rule to remember:

```ruby
Post.select { json_object(title: :title, stars: :meta.dig(:stars)).as(:summary) }
# jsonb_build_object('title', "title", 'stars', "meta" #> '{stars}')   PostgreSQL
# JSON_OBJECT('title', "title", 'stars', JSON_EXTRACT(…))              elsewhere

Post.where { :meta.dig(:author) == json_object(name: :name) }
```

A Ruby value among the arguments goes in as its JSON self — a string or a
number as themselves, `nil` as `null`, and a boolean or a whole document
through the same route `bury` takes them, so SQLite's `true` is not its
`1`. A key that is not a string or a symbol is refused, before the
adapters answer a NULL key three ways. The empty calls stand —
`json_array()` is `[]` and `json_object()` is `{}` on all four — and what
comes back is JSON as `dig`'s is, so the operations and comparisons above
read it.

`json_arrayagg` and `json_objectagg` gather rows into one JSON document — a
value from each row into an array, a key and a value into an object. The
names are the SQL standard's, which the MySQL family says as written;
PostgreSQL is asked the `jsonb` pair and SQLite its own:

```ruby
Post.group { :author_id }.select { json_arrayagg(:title).as(:titles) }
# jsonb_agg("title")          PostgreSQL
# json_group_array("title")   SQLite
# JSON_ARRAYAGG("title")      MySQL

Post.select { json_objectagg(:title, :meta.dig(:stars)).as(:stars) }

Post.group { :author_id }.
  select { json_arrayagg(json_object(title: :title, stars: :meta.dig(:stars))).as(:posts) }
```

What they give is JSON as `dig`'s is, so it compares the way a dug value
does, and `filter` and `over` come along as with any aggregate — with two
refusals where a respelling would change the meaning rather than the
spelling. The MySQL family has no `FILTER`, and the `CASE` that stands in
for it elsewhere would leave a JSON `null` in the document for every row it
drops, so there `filter` raises `NotImplementedError`; MariaDB takes every
other aggregate as a window function but not these two, so `over` raises
there too.

The documents agree across adapters, up to the edges of their JSON types.
Over no rows at all SQLite answers `[]` and `{}` where the others answer
`NULL`, as their aggregates do. A key aggregated twice keeps the last pair
on the JSON types — `jsonb` and MySQL's — and every pair on the text ones,
SQLite and MariaDB, and a `NULL` key is an error on the former pair and a
dropped pair on the latter. And a bare JSON *column* is text to SQLite's
`json_group_array`, so it lands as the string that spells the document
rather than nesting as it does on the other three; a dug value nests
everywhere, so `json_arrayagg(:meta.dig(:author))` is the portable way to
collect part of a document.

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
none. Named windows — `WINDOW w AS (...)` — have no clause in Active Record to
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

`update_all` reads its hash the way Active Record does — `update_all(likes: :likes)`
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
Active Record's own `on_duplicate:` takes SQL text and nothing else, so this is
the one place the DSL writes SQL out itself rather than handing Arel a tree —
and the two cannot both be given.

`insert_all` has no block: its values are literals by construction.
Active Record type-casts each one on the way into the `VALUES` list, so an
expression does not become SQL there — it becomes nothing, silently. Use
`upsert_all` where a row's value has to be worked out.

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
class AcmeDialect < ActiveRecord::Refined::Dialect
  # AcmeDB spells char_length LEN, and has no random ordering.
  FUNCTIONS = { char_length: "LEN", rand: nil }.freeze

  def full_outer_join_supported? = false
end

ActiveRecord::Refined::Dialect.register("acmedb", AcmeDialect)
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
bundle exec bump patch --tag # or bump {major,minor} etc.
git push --follow-tags
```

## Contributing

1. Fork it
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create new Pull Request
