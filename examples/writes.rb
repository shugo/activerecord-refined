$LOAD_PATH.unshift(File.join(File.dirname(__FILE__), '..', 'lib'))

require 'active_record'
require 'activerecord-refined'

ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: ':memory:')
ActiveRecord::Migration.verbose = false

class Setup < ActiveRecord::Migration[8.1]
  def up
    create_table(:pages) do |t|
      t.string :path
      t.integer :hits
      t.integer :bonus
      t.string :title
      t.index :path, unique: true
    end
  end
end
Setup.new.up

class Page < ActiveRecord::Base
end

Page.create!(path: '/index', hits: 10, bonus: 1, title: 'home')
Page.create!(path: '/about', hits: 3,  bonus: 0, title: 'about us')
Page.create!(path: '/faq',   hits: 0,  bonus: 5, title: 'faq')

# These statements run rather than being built, so unlike the other examples
# the SQL is taken from the notification ActiveRecord sends for each one.
def write(title)
  statements = []
  subscriber = ActiveSupport::Notifications.subscribe('sql.active_record') do |*, payload|
    statements << payload[:sql] unless %w[SCHEMA TRANSACTION].include?(payload[:name])
  end
  yield
  ActiveSupport::Notifications.unsubscribe(subscriber)
  puts "--- #{title} ---"
  statements.each {|sql| puts sql }
  Page.order(:path).each {|p| puts "  #{p.path} hits=#{p.hits} title=#{p.title}" }
  puts
end

# 1. update_all.  ActiveRecord reads its hash as literals -- update_all(hits:
#    :hits) would set the column to the symbol itself -- and the block reads a
#    symbol as the column it names, which is what lets the new value be worked
#    out from the old.
write('hits made from the old hits') do
  Page.where { :hits > 0 }.update_all { {hits: :hits + :bonus} }
end

write('a function over the column') do
  Page.update_all { {title: upper(:title)} }
end

# An expression as involved as any other block builds.
write('CASE in an update') do
  Page.update_all { {hits: case_when { :hits > 10 }.then(10).else(:hits)} }
end

# 2. upsert_all.  The block is the part that decides what happens to a row
#    that is already there, and excluded is the row that could not be
#    inserted.  PostgreSQL and SQLite name it that; MySQL says VALUES(column),
#    and the block comes out as whichever the adapter reads.
incoming = [
  {path: '/index', hits: 100, bonus: 0, title: 'HOME'},
  {path: '/new',   hits: 7,   bonus: 0, title: 'NEW'},
]
write('the old value and the new one added together') do
  Page.upsert_all(incoming, unique_by: :path) { {hits: :hits + excluded(:hits)} }
end

# Without a block, upsert_all overwrites -- that is ActiveRecord's own
# behaviour, and the block is what makes the old value reachable.
write('and without a block it is a plain overwrite') do
  Page.upsert_all([{path: '/index', hits: 1, bonus: 0, title: 'HOME'}],
                  unique_by: :path)
end

# insert_all has no block: ActiveRecord type-casts each value into the VALUES
# list, so an expression there would become nothing rather than SQL.
write('insert_all takes literals') do
  Page.insert_all([{path: '/legal', hits: 0, bonus: 0, title: 'legal'}])
end
