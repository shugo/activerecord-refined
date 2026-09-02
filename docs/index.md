# activerecord-refined

Adding clean and powerful query syntax on Active Record using refinements.

```ruby
Author.
  joins(:posts) { :posts[:author_id] == :authors[:id] }.
  where { :authors[:age].in?(20..40) & (:posts[:published] == true) }
# SELECT "authors".* FROM "authors"
#   INNER JOIN "posts" ON "posts"."author_id" = "authors"."id"
#   WHERE "authors"."age" BETWEEN 20 AND 40 AND "posts"."published" = TRUE
```

## Reference

- {ActiveRecord::Refined::BlockSyntax BlockSyntax} — what a symbol answers to
  inside a block: `as`, `asc`, `desc`, `collate`, `[]`, and through it the
  conditions of {ActiveRecord::Refined::AST::Predications Predications} and
  the operators of {ActiveRecord::Refined::AST::Arithmetics Arithmetics}.
- {ActiveRecord::Refined::BlockContext BlockContext} — what a block can call:
  the aggregates, the scalar and window functions, `CASE`, `sql`, `fn`.
- {ActiveRecord::Refined::QueryMethods QueryMethods} — what the relation
  takes: the block forms of `where` and the rest, the joins, `from_cte`,
  `distinct_on`, `lateral`.
- {ActiveRecord::Refined::Writes Writes} — `update_all` and `upsert_all` with
  a block.
- {ActiveRecord::Refined::Dialect Dialect} — one class per family of SQL
  spellings, and `register` for an adapter of your own.

## Guides

One topic at a time, each with the SQL it builds and where the adapters
differ:

- {file:docs/conditions.md Conditions} — comparisons, `LIKE`, `IN`, `NULL`,
  `true?`, regular expressions, subqueries, `ANY` and `ALL`, arrays.
- {file:docs/joins.md Joins} — the `ON` as a block, table aliases, subqueries
  and `LATERAL`.
- {file:docs/functions.md Aggregates and functions} — `count`, `filter`,
  `string_agg`, the scalar functions, the clock, durations, `extract` and
  `cast`.
- {file:docs/expressions.md Expressions} — arithmetic, the bitwise operations,
  `CASE`.
- {file:docs/json.md JSON} — `dig`, `bury`, `except`, `key?`, `keys`, the
  JSON aggregates, and where the adapters' JSON types part.
- {file:docs/windows.md Window functions} — `over`, `partition`, `order`,
  frames.
- {file:docs/ordering.md Aliases, ordering and collation}
- {file:docs/grouping.md Grouping} — `DISTINCT ON`, `GROUPING SETS`,
  `ROLLUP`, `CUBE`.
- {file:docs/ctes.md Common table expressions} — `with_recursive` and
  `from_cte`.
- {file:docs/writing.md Writing} — `update_all` and `upsert_all`.
- {file:docs/time_zones.md Time zones} — what a block converts and what it
  leaves to the session.
