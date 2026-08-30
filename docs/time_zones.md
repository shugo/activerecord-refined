# Time zones


Active Record stores a datetime in UTC unless `ActiveRecord.default_timezone`
says `:local`, and a value a block quotes follows it: a `Time` on the right of
a comparison is converted the way Active Record converts one, so
`where { :created_at > Time.current - 1.day }` is right whatever `Time.zone`
is. What is not converted is what the database says the time is.

`current_timestamp` and its relatives are the server's clock in the session's
zone. Active Record sets PostgreSQL's session to UTC and SQLite's clock is UTC
already, so on those two the clock and the stored values agree. MySQL's
session keeps the server's own zone, so a server that sits in Tokyo answers
`CURRENT_TIMESTAMP` nine hours off the values Active Record stored; set the
session in `database.yml` — `variables: { time_zone: "+00:00" }` — or write
`Time.current` in the block instead, which is right everywhere. SQL Server
answers in its operating system's zone and Oracle in the client's, where
`Time.current` is again the one to reach for. `current_date` is today in UTC,
which in Tokyo is still yesterday until nine in the morning; `Date.current`
says the day meant.

`extract`, `date_trunc` and a `group` by day cut at UTC's midnight. A zone
without daylight saving is a fixed offset away —
`date_trunc("day", :created_at + 9.hours)` — and one with it needs the
database's own `AT TIME ZONE`, through `sql`.

A datetime computed in the query, `(:created_at + 1.hour).as(:later)`, has no
column to take a type from, so it comes back as a `Time` in UTC — as text on
SQLite — with no `Time.zone` applied; `in_time_zone` on the Ruby side does
that.
