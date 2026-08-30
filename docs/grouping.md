# Grouping

## Keeping one row per group


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

## Grouping several ways at once


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
