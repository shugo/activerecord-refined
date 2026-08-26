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
