# Aggregates and functions


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
`COUNT(DISTINCT ...)`. `sum` and `avg` take `distinct: true` as well, for the
aggregate over each value once; `min` and `max` would give the same with or
without it, so they take no such thing:

```ruby
Author.group { :country }.having { count(:*) > 1 }
# SELECT "authors".* FROM "authors" GROUP BY "authors"."country" HAVING COUNT(*) > 1

Post.select { count(:author_id, distinct: true) }   # COUNT(DISTINCT "author_id")
Post.select { sum(:likes, distinct: true) }         # SUM(DISTINCT "likes")
```

`string_agg` joins the strings of a group into one, a separator between —
`,` unless another is given — and `.order` says the order they are joined
in. Each database has it under a name of its own, with the `ORDER BY` in a
place of its own:

```ruby
Post.group { :author_id }.select { string_agg(:title, ", ").order(:title).as(:titles) }
# STRING_AGG("title", ', ' ORDER BY "title")                  PostgreSQL
# group_concat("title", ', ' ORDER BY "title")                SQLite
# GROUP_CONCAT("title" ORDER BY "title" SEPARATOR ', ')       MySQL
# STRING_AGG("title", ', ') WITHIN GROUP (ORDER BY "title")   SQL Server
# LISTAGG("title", ', ') WITHIN GROUP (ORDER BY "title")      Oracle
```

`filter` and `over` come along as with any aggregate, `over` where the
database takes it — the MySQL family and SQL Server do not, and raise.
Oracle's insists on an order and is given the values' own when none is asked
for. What is joined is text: PostgreSQL's `STRING_AGG` takes nothing else, so
a column the model does not declare a string is cast there, where the others
convert for themselves. MySQL cuts the result at `group_concat_max_len`, 1024
bytes unless the session says otherwise, and the `ORDER BY` inside SQLite's
call needs SQLite 3.44.

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
# SELECT date_trunc('day', "posts"."created_at") AS "day"
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
does not — and SQL Server, which has none of the other four:

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
# SELECT CAST("posts"."price" AS decimal(10,2)) AS "price"
```

A duration moves a date. Active Support's `7.days` and the rest go on the
right of `+` or `-`, and the move comes out the way the adapter spells it — an
`INTERVAL` literal on PostgreSQL and MySQL, `DATEADD` on SQL Server,
`datetime(x, '-7 day')` on SQLite:

```ruby
Post.where { :created_at > current_timestamp - 7.days }
# WHERE "posts"."created_at" > (CURRENT_TIMESTAMP - INTERVAL '7' DAY)

Post.select { (:published_on + 1.month).as(:review_on) }
```

A duration of several parts, `1.month + 2.days`, is applied a part at a time
in the order Active Support keeps them, and a week is seven days, which is
what SQLite and Oracle have of one. Each part has to be a whole number, since
it is written into the SQL as one: `1.5.days` raises `ArgumentError`. SQLite
has no date type, so there a column the model declares a date is moved by
`date()` and stays a date; everything else goes through `datetime()` and comes
back with a time of day.
