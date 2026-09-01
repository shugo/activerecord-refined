# Expressions


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

`bitwise_and`, `bitwise_or`, `^`, `~`, `<<` and `>>` are SQL's bitwise
operations. The first two are named rather than spelled `&` and `|`, which
mean AND and OR between conditions and nothing else anywhere; `bitwise_xor`
and `bitwise_not` stand beside `^` and `~` for a reader who would rather have
the name:

```ruby
Post.where { :flags.bitwise_and(4) > 0 }
# WHERE ("posts"."flags" & 4) > 0

Post.select { :flags.bitwise_or(4).as(:flags) }
Post.select { (~:flags).as(:inverted) }
```

A method binds tighter than any comparison, so nothing has to be parenthesised
to be compared. Each operation parenthesises itself in the SQL as well, since
PostgreSQL gives `&` and `|` the same precedence and reads `a | b & c` from
the left.

Reaching for the operator on a column says which name was meant:

```ruby
Post.where { :flags & 4 }
# ArgumentError: & between conditions is AND; bitwise_and is SQL's bitwise operator
```

Oracle has none of the operators — its one bit operation is the `BITAND`
function — and the block refuses every one there rather than leaving its
server to.

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
# SELECT "nodes"."id", 0 AS "depth" FROM "nodes"

Node.select { [:id, 0.as(:depth)] }         # the same thing

Post.select { [:title, "draft".as(:state)] }
# SELECT "posts"."title", 'draft' AS "state" FROM "posts"
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
# CASE "country" WHEN 'JP' THEN 'Japan' ELSE 'elsewhere' END AS "where"

Author.select { case_when { :age >= 60 }.then("senior").else("adult").as(:band) }
# CASE WHEN "age" >= 60 THEN 'senior' ELSE 'adult' END AS "band"

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
# SUM(CASE WHEN "age" >= 60 THEN 1 ELSE 0 END) AS "seniors"
```
