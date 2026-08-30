# JSON


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
