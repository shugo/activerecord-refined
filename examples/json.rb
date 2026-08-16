$LOAD_PATH.unshift(File.join(File.dirname(__FILE__), '..', 'lib'))

require 'active_record'
require 'activerecord-refined'

ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: ':memory:')
ActiveRecord::Migration.verbose = false

class Setup < ActiveRecord::Migration[8.1]
  def up
    create_table(:documents) {|t| t.string :name; t.json :meta }
  end
end
Setup.new.up

class Document < ActiveRecord::Base
end

Document.create!(name: 'guide',
  meta: {'author' => {'name' => 'alice', 'country' => 'JP'},
         'tags' => %w[ruby sql], 'views' => 120, 'draft' => false})
Document.create!(name: 'notes',
  meta: {'author' => {'name' => 'bob'}, 'tags' => ['ruby'], 'views' => 8})
Document.create!(name: 'empty', meta: {})

def show(title, relation, rows = nil)
  puts "--- #{title} ---"
  puts relation.to_sql
  puts rows.inspect unless rows.nil?
  puts
end

# 1. Reading.  dig_text takes the path Hash#dig takes: a string or symbol
#    steps into an object, an integer into an array.  What comes back is the
#    value rather than the JSON around it, which is what a comparison wants.
show('dig_text reads a value out of the document',
  Document.select { [:name, :meta.dig_text(:author, :name).as(:author)] },
  Document.select { [:name, :meta.dig_text(:author, :name).as(:author)] }.
    map {|d| [d.name, d.author] })

show('an integer steps into an array',
  Document.select { [:name, :meta.dig_text(:tags, 0).as(:first_tag)] },
  Document.select { [:name, :meta.dig_text(:tags, 0).as(:first_tag)] }.
    map {|d| [d.name, d.first_tag] })

# A dug value is an expression like any other, so it compares and orders.
show('dig_text in a condition',
  Document.where { :meta.dig_text(:author, :country) == 'JP' },
  Document.where { :meta.dig_text(:author, :country) == 'JP' }.pluck(:name))

# A dug value is text, so a number goes through a cast.  Comparing it with
# one instead is refused rather than left to the adapters, which answer that
# three ways: true here, an error on PostgreSQL, true on MySQL.
show('a number wants a cast',
  Document.where { cast(:meta.dig_text(:views), 'integer') > 100 },
  Document.where { cast(:meta.dig_text(:views), 'integer') > 100 }.pluck(:name))

begin
  Document.where { :meta.dig_text(:views) > 100 }
rescue ArgumentError => e
  puts '--- and without one it says so ---'
  puts "  #{e.message}"
  puts
end

# dig keeps the JSON, for a part of the document to be dug into further
# or asked the JSON questions.  The quotes around the string are the sign of
# it -- and the reason a Ruby value is refused on this side too.
show('dig keeps the JSON',
  Document.select { [:name, :meta.dig(:author).as(:author)] },
  Document.select { [:name, :meta.dig(:author).as(:author)] }.
    map {|d| [d.name, d.author] })

# 2. Asking whether a key is there at all, which is not the same as asking
#    whether its value is null -- and is spelled key? for the reason Ruby's
#    Hash spells it that way.
show('key? asks whether the key is there',
  Document.where { :meta.key?(:draft) },
  Document.where { :meta.key?(:draft) }.pluck(:name))

# key? takes the one key Hash#key? takes; a path is what dig is for.
show('and ! is its negation',
  Document.where { !:meta.key?(:draft) },
  Document.where { !:meta.key?(:draft) }.pluck(:name))

# 3. Writing.  bury sets what dig reads, at the path given: JSON_SET on SQLite
#    and MySQL, jsonb_set on PostgreSQL.
show('the expression bury builds',
  Document.select { [:name, :meta.bury(:author, :country, 'US').as(:updated)] })

# It is an expression, so it is what update_all sets the column to.
Document.where { :name == 'notes' }.update_all { {meta: :meta.bury(:author, :country, 'US')} }
puts '--- what the update left behind ---'
puts "  #{Document.find_by(name: 'notes').meta.inspect}"
puts

# A whole object or array goes in at once.
Document.where { :name == 'empty' }.update_all { {meta: :meta.bury(:author, {'name' => 'carol'})} }
puts '--- a whole object at once ---'
puts "  #{Document.find_by(name: 'empty').meta.inspect}"
puts

# The path is what makes the SQL, so it cannot be empty.
begin
  Document.select { :meta.bury('US') }
rescue ArgumentError => e
  puts '--- bury needs a path ---'
  puts "  #{e.message}"
  puts
end

# 4. Taking keys out again, as Hash#except does: keys of the document rather
#    than a path, however many of them, and a key that is not there is no
#    error.  The document comes back changed, so it chains with bury.
show('the expression except builds',
  Document.select { [:name, :meta.except(:views, :draft).as(:trimmed)] })

Document.where { :name == 'guide' }.
  update_all { {meta: :meta.bury(:author, :country, 'JP').except(:tags, :views)} }
puts '--- buried and excepted in one statement ---'
puts "  #{Document.find_by(name: 'guide').meta.inspect}"
puts
