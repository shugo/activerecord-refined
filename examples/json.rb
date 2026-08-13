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

# 1. Reading.  dig takes the path Hash#dig takes: a string or symbol steps
#    into an object, an integer into an array.  What comes back is the value
#    rather than the JSON around it, which is what a comparison wants.
show('dig reads a value out of the document',
  Document.select { [:name, :meta.dig(:author, :name).as(:author)] },
  Document.select { [:name, :meta.dig(:author, :name).as(:author)] }.
    map {|d| [d.name, d.author] })

show('an integer steps into an array',
  Document.select { [:name, :meta.dig(:tags, 0).as(:first_tag)] },
  Document.select { [:name, :meta.dig(:tags, 0).as(:first_tag)] }.
    map {|d| [d.name, d.first_tag] })

# A dug value is an expression like any other, so it compares and orders.
show('dig in a condition',
  Document.where { :meta.dig(:author, :country) == 'JP' },
  Document.where { :meta.dig(:author, :country) == 'JP' }.pluck(:name))

# dig_json keeps the JSON, for a part of the document to be dug into further
# or compared whole.  The quotes around the string are the sign of it.
show('dig_json keeps the JSON',
  Document.select { [:name, :meta.dig_json(:author).as(:author)] },
  Document.select { [:name, :meta.dig_json(:author).as(:author)] }.
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
