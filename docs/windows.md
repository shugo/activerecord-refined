# Window functions


`over` gives a function a window, which is what turns an aggregate into a
running one and the only thing `row_number` and its kind can be used with.
The window is built by chaining, as Arel's own is:

```ruby
Author.select { avg(:age).over.partition(:country).as(:country_average) }
# AVG("age") OVER (PARTITION BY "country") AS country_average

Author.select { row_number.over.partition(:country).order(:age.desc).as(:rank) }
# ROW_NUMBER() OVER (PARTITION BY "country" ORDER BY "age" DESC) AS rank

Author.select { count(:*).over.as(:total) }   # COUNT(*) OVER () — every row
```

`row_number`, `rank`, `dense_rank`, `percent_rank`, `cume_dist`, `ntile`,
`lag`, `lead`, `first_value`, `last_value` and `nth_value` are the functions
that say nothing without a window; each raises `ArgumentError` if `over` never
arrives, rather than reaching the database as an error there. Every adapter
that has window functions at all spells them the same way, so unlike the
scalar functions there is nothing here to translate.

A frame is a range of rows counted from the current one — negative before it,
positive after, 0 the row itself, and an open end for unbounded:

```ruby
Post.select { sum(:likes).over.order(:created_at).rows(..0).as(:running) }
# SUM("likes") OVER (ORDER BY "created_at" ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)

Post.select { avg(:likes).over.order(:created_at).rows(-1..1).as(:smoothed) }
# ... ROWS BETWEEN 1 PRECEDING AND 1 FOLLOWING

Post.select { sum(:likes).over.order(:created_at).rows(0..).as(:remaining) }
# ... ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
```

`range` says `RANGE` where `rows` says `ROWS`, and a window has one frame or
none. Named windows — `WINDOW w AS (...)` — have no clause in Active Record to
live in, so they are not here.
