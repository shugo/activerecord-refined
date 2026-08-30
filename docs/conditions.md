# Conditions


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
