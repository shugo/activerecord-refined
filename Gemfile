# frozen_string_literal: true

source "https://rubygems.org"

# Specify your gem's dependencies in activerecord-refined.gemspec
gemspec

# Only the server adapters need a client gem, and building one needs its
# client library installed, so each sits in an optional group named after
# its adapter: a plain bundle serves `rake test` on SQLite with nothing
# extra, and a run opts in to exactly the adapters it will reach --
#
#   bundle config set --local with postgresql mysql2 trilogy
#
# -- which is what the devcontainer wants, its servers being PostgreSQL and
# MariaDB.
group :postgresql, optional: true do
  gem "pg"
end

group :mysql2, optional: true do
  gem "mysql2"
end

group :trilogy, optional: true do
  gem "trilogy"
end

# oracle_enhanced reaches Oracle through ruby-oci8, whose build needs Oracle
# Instant Client and whose released version does not compile on ruby-master
# -- its git HEAD does.
group :oracle, optional: true do
  gem "ruby-oci8", git: "https://github.com/kubo/ruby-oci8"
  gem "activerecord-oracle_enhanced-adapter"
end

# sqlserver reaches SQL Server through tiny_tds, whose build needs FreeTDS.
group :sqlserver, optional: true do
  gem "tiny_tds"
  gem "activerecord-sqlserver-adapter"
end
