# Joins

## Joins


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

## Lateral joins


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
