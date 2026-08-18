$LOAD_PATH.unshift(File.join(File.dirname(__FILE__), '..', 'lib'))

require 'active_record'
require 'activerecord-refined'
require 'etc'

# What is here is what SQLite cannot run, so unlike the other examples this
# one needs a server.  Most of it is PostgreSQL's alone; ANY and ALL, JSON
# containment, the bit aggregates and LATERAL are MySQL's too.  It connects the way the test suite does: on 127.0.0.1 as
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
    create_table(:writers, force: true) {|t| t.string :name; t.string :country }
    create_table(:articles, force: true) do |t|
      t.string :title
      t.string :tags, array: true, default: []
      t.integer :scores, array: true, default: []
      t.integer :writer_id
      t.integer :likes
      t.integer :flags
      t.jsonb :meta
    end
  end
end
Setup.new.up

class Writer < ActiveRecord::Base
end

class Article < ActiveRecord::Base
  belongs_to :writer
end

Article.delete_all
Writer.delete_all
alice = Writer.create!(name: 'alice', country: 'JP')
bob   = Writer.create!(name: 'bob',   country: 'JP')
carol = Writer.create!(name: 'carol', country: 'US')
Article.create!(title: 'Refinements',   tags: %w[ruby lang],   scores: [5, 4],
                writer: alice, likes: 120, flags: 5, meta: {'draft' => false, 'lang' => 'ja'})
Article.create!(title: 'Rails 8',       tags: %w[ruby rails],  scores: [5],
                writer: alice, likes: 80,  flags: 1, meta: {'draft' => false})
Article.create!(title: 'Postgres CTEs', tags: %w[sql db],      scores: [3],
                writer: bob,   likes: 30,  flags: 3, meta: {'draft' => true})
Article.create!(title: '100% pure',     tags: ['100%', 'a,b'], scores: [],
                writer: carol, likes: 5,   flags: 4, meta: {'draft' => true, 'lang' => 'ja'})

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

# 5. Keeping one row per group.  DISTINCT ON is PostgreSQL's: the first row of
#    each group the order brings up, which is why the order has to start with
#    what the distinct is on.  Arel refuses to write it for the others, so the
#    portable shape is a row_number window in a subquery.
show('the most liked article of each writer',
  Article.distinct_on { :writer_id }.order { [:writer_id, :likes.desc] },
  Article.distinct_on { :writer_id }.order { [:writer_id, :likes.desc] }.
    pluck(:title))

# 6. Grouping several ways at once.  Each grouping set produces its own rows,
#    and an empty one is the grand total; rollup and cube are the two shapes
#    that come up often enough to have names of their own.  MySQL has only
#    WITH ROLLUP, which is a different clause, and SQLite has none of it.
sets = Article.
  joins(:writers) { :writers[:id] == :articles[:writer_id] }.
  group { grouping_sets([:writers[:country]], [:articles[:writer_id]], []) }.
  select { [:writers[:country], :articles[:writer_id], sum(:likes).as(:likes)] }
show('by country, by writer, and both together',
  sets,
  sets.map {|a| [a.country, a.writer_id, a.likes] })

# rollup runs on MySQL and MariaDB too, as their WITH ROLLUP; the other two
# groupings are PostgreSQL's alone.
show('rollup is the nested case of the same thing',
  Article.group { rollup(:writer_id, :flags) }.select { [:writer_id, :flags, count(:*).as(:n)] })

# 7. Lateral joins.  A lateral join lets the relation joined see the row being
#    joined to, which is what makes the top row of each group reachable in one
#    query.  Without a block the join is ON TRUE, the usual shape: what the
#    subquery may see is said in its own where.
top = Article.select { :title }.
  where { :articles[:writer_id] == :writers[:id] }.
  order { :likes.desc }.limit(1)
lateral = Writer.left_outer_joins(top.lateral, as: :top).
  select { [:name, :top[:title].as(:top_article)] }
show('the top article beside each writer',
  lateral,
  lateral.map {|w| [w.name, w.top_article] })

# 8. ANY and ALL, which quantify a comparison over a subquery where a scalar
#    subquery would have to return the one row.  MySQL has them too; SQLite
#    has neither, and says so rather than leaving its parser to.
show('more liked than some article of alice, and than all of them',
  Article.where { :likes > any(Article.where { :writer_id == alice.id }.select(:likes)) },
  [
    Article.where { :likes > any(Article.where { :writer_id == alice.id }.select(:likes)) }.
      pluck(:title),
    Article.where { :likes > all(Article.where { :writer_id == alice.id }.select(:likes)) }.
      pluck(:title),
  ])

# 9. JSON containment and the bit aggregates, which PostgreSQL and MySQL have
#    and SQLite does not.  contains? asks whether the document holds the one
#    given, which is @> here and JSON_CONTAINS on MySQL.
show('containment asks about a whole document',
  Article.where { :meta.contains?(draft: true) },
  Article.where { :meta.contains?(draft: true) }.pluck(:title))

# A JSON comparison belongs to the JSON types -- jsonb here, MySQL's JSON
# too: numbers compare as numbers, documents structurally.  SQLite and
# MariaDB have only the text of each and raise.
show('a dug value compares with a Ruby one directly',
  Article.where { :meta.dig(:draft) == true },
  Article.where { :meta.dig(:draft) == true }.pluck(:title))

show('the bits every article has, and the bits any of them has',
  Article.select { [bit_and(:flags).as(:common), bit_or(:flags).as(:any)] },
  Article.select { [bit_and(:flags).as(:common), bit_or(:flags).as(:any)] }.
    map {|a| [a.common, a.any] })

show('and how many bits are set in each',
  Article.select { [:title, bit_count(:flags).as(:bits)] },
  Article.select { [:title, bit_count(:flags).as(:bits)] }.map {|a| [a.title, a.bits] })
