# Aliases, ordering and collation

## Aliases and ordering


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

## Collation


`.collate` names a collation for a comparison or an ordering — how the
database decides two strings are equal and which comes first — and gives back
an expression, so the collation carries into either:

```ruby
Author.where { :name.collate(:nocase) == "alice" }
# WHERE "authors"."name" COLLATE nocase = 'alice'

Author.order { :name.collate(:nocase).asc }
```

The collation names are the database's own, so they are not portable — SQLite's
`nocase`, PostgreSQL's `"C"`, MySQL's `utf8mb4_bin`. PostgreSQL folds an
unquoted name to lower case, where its built-in names are upper, so it quotes
the name for you.

On the databases that take the name bare, it has to be a plain identifier: a
hyphen would read as a subtraction, so a name with one is refused. PostgreSQL
quotes the name, so a hyphen is safe there, and its ICU collations —
`en-US-x-icu` and the rest — are spelled with them.
