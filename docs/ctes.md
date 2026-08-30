# Common table expressions


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
SQL — see [`value`](functions.md) for why a number can say `.as` directly.

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
