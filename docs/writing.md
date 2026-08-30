# Writing


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
