$LOAD_PATH.unshift(File.join(File.dirname(__FILE__), '..', 'lib'))

require 'active_record'
require 'activerecord-refined'
require 'etc'

# The features here are PostgreSQL's, so unlike the other examples this one
# needs a server.  It connects the way the test suite does: on 127.0.0.1 as
# the current user with no password, overridable through DB_HOST, DB_USERNAME
# and DB_PASSWORD.
begin
  ActiveRecord::Base.establish_connection(
    adapter: 'postgresql',
    host: ENV.fetch('DB_HOST', '127.0.0.1'),
    username: ENV.fetch('DB_USERNAME') { Etc.getlogin },
    password: ENV['DB_PASSWORD'],
    database: ENV.fetch('DB_NAME', 'postgres'))
  ActiveRecord::Base.lease_connection
rescue StandardError => e
  abort "needs a PostgreSQL server: #{e.message}"
end

ActiveRecord::Migration.verbose = false

class Setup < ActiveRecord::Migration[8.1]
  def up
    create_table(:articles, force: true) do |t|
      t.string :title
      t.string :tags, array: true, default: []
      t.integer :scores, array: true, default: []
    end
  end
end
Setup.new.up

class Article < ActiveRecord::Base
end

Article.delete_all
Article.create!(title: 'Refinements',  tags: %w[ruby lang],  scores: [5, 4])
Article.create!(title: 'Rails 8',      tags: %w[ruby rails], scores: [5])
Article.create!(title: 'Postgres CTEs', tags: %w[sql db],    scores: [3])
Article.create!(title: '100% pure',    tags: ['100%', 'a,b'], scores: [])

def show(title, relation, rows = nil)
  puts "--- #{title} ---"
  puts relation.to_sql
  puts rows.inspect unless rows.nil?
  puts
end

# 1. Array columns.  Each name carries the meaning of its Ruby namesake:
#    member? is Enumerable's element test, superset? and subset? are Set's
#    containment, and intersect? is Array's "any element in common".
show('member? tests one element',
  Article.where { :tags.member?('ruby') },
  Article.where { :tags.member?('ruby') }.pluck(:title))

show('superset? requires every element',
  Article.where { :tags.superset?(%w[ruby rails]) },
  Article.where { :tags.superset?(%w[ruby rails]) }.pluck(:title))

show('subset? and intersect?',
  Article.where { :tags.intersect?(%w[sql lang]) },
  [
    Article.where { :tags.subset?(%w[ruby lang extra]) }.pluck(:title),
    Article.where { :tags.intersect?(%w[sql lang]) }.pluck(:title),
  ])

# The element is serialized into an array literal, so commas, quotes and %
# are matched literally rather than parsed or treated as wildcards.
show('elements are matched literally',
  Article.where { :tags.member?('a,b') },
  Article.where { :tags.member?('a,b') }.pluck(:title))

# member? works on any element type; the literal is coerced to the column's.
show('a numeric array',
  Article.where { :scores.member?(4) },
  Article.where { :scores.member?(4) }.pluck(:title))

# 2. Regular expressions.  =~ and !~ become ~ and !~ here, REGEXP on MySQL.
#    SQLite has no regexp operator, which is why this example is not one of
#    the portable ones.
show('=~ matches a regular expression',
  Article.where { :title =~ '^R' },
  Article.where { :title =~ '^R' }.pluck(:title))

show('a Regexp literal works too, and !~ negates',
  Article.where { :title !~ /s$/ },
  Article.where { :title !~ /s$/ }.pluck(:title))

# 3. Case.  like? is case-sensitive LIKE everywhere, including here, where
#    Arel would otherwise reach for ILIKE.  ilike? is the one that asks for
#    it, and casecmp? is case-insensitive equality.
show('like? stays case-sensitive; ilike? does not',
  Article.where { :title.ilike?('r%') },
  [
    Article.where { :title.like?('r%') }.pluck(:title),
    Article.where { :title.ilike?('r%') }.pluck(:title),
  ])

# 4. NULL as a value.  PostgreSQL spells this IS [NOT] DISTINCT FROM.
show('null-safe comparison',
  Article.where { :title.not_distinct_from?('Rails 8') },
  Article.where { :title.not_distinct_from?('Rails 8') }.pluck(:title))
