# Runs once when the sandbox starts.  Sets up an in-memory SQLite database and
# the models the examples use, then defines the helpers the examples call.

# ruby.wasm starts with RubyGems disabled, so Gem is not defined.  ActiveSupport's
# BacktraceCleaner reads Gem.path and Gem.default_dir while ActiveRecord loads,
# so RubyGems has to be pulled in first.
require 'rubygems'

# sqlite3 is compiled into ruby.wasm as a bundled extension rather than
# installed as a gem, so RubyGems has no spec for it and the `gem "sqlite3"`
# call at the top of ActiveRecord's adapter would fail to resolve.  Kernel#gem
# returns early when Gem.loaded_specs already satisfies the requirement, so
# registering the version that is actually built in is enough.
require 'sqlite3'
Gem.loaded_specs['sqlite3'] ||= Gem::Specification.new('sqlite3', SQLite3::VERSION)

require 'active_record'
require 'activerecord-refined'

# reaping_frequency has to be off: the connection pool's reaper runs on a
# Thread, and WASI has no threads (Thread.new raises NotImplementedError).
# Nothing here holds a connection long enough to need reaping anyway.
ActiveRecord::Base.establish_connection(
  adapter: 'sqlite3',
  database: ':memory:',
  reaping_frequency: nil
)
ActiveRecord::Base.logger = nil

ActiveRecord::Schema.verbose = false
ActiveRecord::Schema.define do
  create_table :authors do |t|
    t.string  :name
    t.string  :country
    t.integer :age
  end

  create_table :posts do |t|
    t.integer :author_id
    t.string  :title
    t.boolean :published
    t.integer :likes
  end

  create_table :comments do |t|
    t.integer :post_id
    t.string  :body
  end

  create_table :employees do |t|
    t.string  :name
    t.integer :manager_id
  end

  create_table :items do |t|
    t.string  :name
    t.integer :price
    t.integer :quantity
  end

  create_table :nodes do |t|
    t.string  :name
    t.integer :parent_id
  end
end

class Author < ActiveRecord::Base
  has_many :posts
end

class Post < ActiveRecord::Base
  belongs_to :author
  has_many :comments

  scope :published, -> { where { :published == true } }
end

class Comment < ActiveRecord::Base
  belongs_to :post
end

class Employee < ActiveRecord::Base; end
class Item < ActiveRecord::Base; end
class Node < ActiveRecord::Base; end

alice = Author.create!(name: 'Alice', country: 'JP', age: 60)
bob   = Author.create!(name: 'Bob',   country: 'JP', age: 47)
carol = Author.create!(name: 'Carol', country: nil,  age: 55)
dave  = Author.create!(name: 'Dave',  country: 'US', age: 46)
Author.create!(name: 'Erin', country: nil, age: 17)

p1 = Post.create!(author: alice, title: 'Ruby 4.1 is coming',    published: true,  likes: 120)
p2 = Post.create!(author: alice, title: 'Refinements revisited', published: true,  likes: 80)
p3 = Post.create!(author: bob,   title: 'YJIT internals',        published: false, likes: 30)
p4 = Post.create!(author: dave,  title: 'A test post',           published: true,  likes: 5)
Post.create!(author: carol, title: 'Patch review notes', published: true, likes: 42)

Comment.create!(post: p1, body: 'Nice')
Comment.create!(post: p1, body: 'Looking forward to it')
Comment.create!(post: p2, body: 'Great write-up')
Comment.create!(post: p3, body: 'Deep')
Comment.create!(post: p4, body: 'Thanks')

boss = Employee.create!(name: 'Boss', manager_id: nil)
lead = Employee.create!(name: 'Lead', manager_id: boss.id)
Employee.create!(name: 'Dev A', manager_id: lead.id)
Employee.create!(name: 'Dev B', manager_id: lead.id)

Item.create!(name: 'Keyboard', price: 120, quantity: 3)
Item.create!(name: 'Monitor',  price: 400, quantity: 2)
Item.create!(name: 'Cable',    price: 10,  quantity: 25)

root  = Node.create!(name: 'root',   parent_id: nil)
child = Node.create!(name: 'child',  parent_id: root.id)
Node.create!(name: 'grandchild', parent_id: child.id)
Node.create!(name: 'sibling',    parent_id: root.id)

# `show` is what the examples call: it prints the SQL a relation builds and then
# the rows it actually returns, so the two can be read side by side.
def show(relation, limit: 20)
  sql = relation.to_sql
  puts sql
  puts

  # Read the rows through the connection rather than through the model, so the
  # columns shown are exactly the ones the SELECT asked for.  Going via the
  # model would add its other attributes back as nil.
  print_result ActiveRecord::Base.connection.select_all("#{sql} LIMIT #{limit.to_i}")
rescue ActiveRecord::StatementInvalid => e
  puts 'The database rejected this query:'
  puts "  #{e.message.lines.first.strip}"
end

# Prints just the SQL, for examples where running the query is beside the point.
def sql(relation)
  puts relation.to_sql
end

# The tables behind the examples, for the Data section of the sidebar.  Asked
# of the connection rather than listed here, so a model added above shows up
# without the page having to be told about it.
def tables
  bookkeeping = /\Aar_internal_|\Asqlite_|\Aschema_migrations\z/
  ActiveRecord::Base.connection.tables.grep_v(bookkeeping).sort
end

# Every row of one table as it stands now -- after whatever the examples, or
# you, have done to it.
def data(table, limit: 50)
  name = tables.find { |t| t == table.to_s } or
    raise ArgumentError, "no such table: #{table} (#{tables.join(', ')})"

  puts "#{name}"
  puts
  print_result ActiveRecord::Base.connection.select_all("SELECT * FROM #{name} LIMIT #{limit.to_i}")
end

def print_result(result)
  if result.empty?
    puts '(no rows)'
    return
  end

  columns = result.columns
  rows = result.rows
  widths = columns.each_with_index.map do |column, i|
    [column.length, *rows.map { |row| row[i].inspect.length }].max
  end

  puts columns.each_with_index.map { |c, i| c.ljust(widths[i]) }.join('  ')
  puts widths.map { |w| '-' * w }.join('  ')
  rows.each do |row|
    puts row.each_with_index.map { |v, i| v.inspect.ljust(widths[i]) }.join('  ')
  end
  puts
  puts "#{rows.size} row(s)"
end
