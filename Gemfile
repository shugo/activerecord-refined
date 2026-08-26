# frozen_string_literal: true

source "https://rubygems.org"

# Specify your gem's dependencies in activerecord-refined.gemspec
gemspec

# Only the server adapters need these, and building them needs the client
# libraries installed.  `rake test` runs on SQLite, so a checkout without
# them is still usable: bundle config set --local without db
group :db do
  gem "mysql2"
  gem "pg"
  gem "trilogy"
end

# oracle_enhanced reaches Oracle through ruby-oci8, whose build needs Oracle
# Instant Client and whose released version does not compile on ruby-master
# -- its git HEAD does.  An optional group keeps all of that out of every
# run but the one that opts in with `bundle --with oracle`, so the other
# adapters, and a plain local bundle, need neither the client nor the
# git checkout.
group :oracle, optional: true do
  gem "ruby-oci8", git: "https://github.com/kubo/ruby-oci8"
  gem "activerecord-oracle_enhanced-adapter"
end
