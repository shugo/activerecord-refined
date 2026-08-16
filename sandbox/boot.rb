# Runs once when the sandbox starts.  Sets up an in-memory database and the
# models the examples use, then defines the helpers the examples call.

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

ActiveRecord::Base.logger = nil
ActiveRecord::Schema.verbose = false

# Which of the two the page is on.  PostgreSQL is PGlite, which is PostgreSQL
# itself compiled to WebAssembly and reached through the adapter under
# pglite/; the DSL cannot tell it from a server.
def postgresql?
  ActiveRecord::Base.connection_db_config.adapter == 'pglite'
end

def current_database
  postgresql? ? 'postgresql' : 'sqlite3'
end

# The page calls this to change database, and once at startup.  Both are in
# memory, so the schema and the sample data are built afresh each time: what
# is being switched to was left in whatever state the examples put it in, and
# starting from the rows the sidebar describes is the point of them.
def use_database(name)
  case name
  when 'sqlite3'
    # reaping_frequency has to be off: the connection pool's reaper runs on a
    # Thread, and WASI has no threads (Thread.new raises NotImplementedError).
    # Nothing here holds a connection long enough to need reaping anyway.
    ActiveRecord::Base.establish_connection(
      adapter: 'sqlite3',
      database: ':memory:',
      reaping_frequency: nil
    )
  when 'postgresql'
    # PostgreSQLAdapter opens with `gem "pg", "~> 1.1"`, and what answers for
    # the gem here is a stub of a few classes, so RubyGems has to be told the
    # requirement is met.  Same reasoning as sqlite3 above.
    Gem.loaded_specs['pg'] ||= Gem::Specification.new('pg', '1.5.9')
    require 'active_record/connection_adapters/pglite'
    ActiveRecord::Base.establish_connection(
      adapter: 'pglite',
      database: 'sandbox',
      reaping_frequency: nil
    )
  else
    raise ArgumentError, "no such database: #{name}"
  end

  define_schema
  # The two schemas are not identical -- an array column is PostgreSQL's alone
  # -- so what the models know about their columns has to be forgotten.
  ActiveRecord::Base.descendants.each(&:reset_column_information)
  seed
  current_database
end

def define_schema
  postgresql = postgresql?

  ActiveRecord::Schema.define do
    create_table :authors, force: true do |t|
      t.string  :name
      t.string  :country
      t.integer :age
    end

    create_table :posts, force: true do |t|
      t.integer :author_id
      t.string  :title
      t.boolean :published
      # A bit field, for the bitwise operators: 1 comments open, 2 pinned,
      # 4 featured.
      t.integer :flags
      t.integer :likes
      # An array of them is a type PostgreSQL has and SQLite has not, so the
      # column exists only where the array operators can be asked about it.
      t.string :tags, array: true if postgresql
    end

    create_table :comments, force: true do |t|
      t.integer :post_id
      t.string  :body
    end

    create_table :employees, force: true do |t|
      t.string  :name
      t.integer :manager_id
    end

    create_table :items, force: true do |t|
      t.string  :name
      t.integer :price
      t.integer :quantity
      # What upsert_all upserts by: a name is what a delivery note carries,
      # where the id is this table's own business.
      t.index :name, unique: true
    end

    create_table :nodes, force: true do |t|
      t.string  :name
      t.integer :parent_id
    end

    create_table :docs, force: true do |t|
      t.string :name
      # jsonb rather than json on PostgreSQL: containment and the rest of the
      # operators the JSON examples use belong to jsonb alone.
      postgresql ? t.jsonb(:meta) : t.json(:meta)
    end
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
class Doc < ActiveRecord::Base; end

def seed
  # The ages are spread so that every example that filters on one has something
  # to show: Erin is the only one under 18, Carol the only one over 50, and the
  # average falls between the two thresholds the examples use.
  alice = Author.create!(name: 'Alice', country: 'JP', age: 38)
  bob   = Author.create!(name: 'Bob',   country: 'JP', age: 26)
  carol = Author.create!(name: 'Carol', country: nil,  age: 52)
  dave  = Author.create!(name: 'Dave',  country: 'US', age: 31)
  Author.create!(name: 'Erin', country: nil, age: 17)

  posts = [
    [alice, 'Ruby 4.1 is coming',      true,  120, 5, %w[ruby release]],
    [alice, 'Refinements revisited',   true,  80,  1, %w[ruby lang]],
    [bob,   'YJIT internals',          false, 30,  3, %w[ruby jit]],
    [dave,  'A test post',             true,  5,   0, %w[meta]],
    [carol, 'Patch review notes',      true,  42,  4, %w[ruby lang review]],
    # Nobody has said either way about the last one, which is what the truth
    # tests are there to tell apart from a plain false.
    [bob,   'Pattern matching notes',  nil,   0,   6, %w[ruby lang]],
  ].map do |author, title, published, likes, flags, tags|
    attributes = {author: author, title: title, published: published,
                  likes: likes, flags: flags}
    attributes[:tags] = tags if postgresql?
    Post.create!(**attributes)
  end
  p1, p2, p3, p4 = posts

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

  # Two trees rather than one: walking the first has to leave the second behind,
  # which is the whole point of the recursive example and invisible if every row
  # in the table is a descendant of the same root.
  root  = Node.create!(name: 'root',   parent_id: nil)
  child = Node.create!(name: 'child',  parent_id: root.id)
  Node.create!(name: 'grandchild', parent_id: child.id)
  Node.create!(name: 'sibling',    parent_id: root.id)

  other = Node.create!(name: 'other root',  parent_id: nil)
  Node.create!(name: 'other child', parent_id: other.id)

  Doc.create!(name: 'first',  meta: { 'author' => { 'name' => 'Alice' }, 'tags' => %w[ruby sql], 'stars' => 5 })
  Doc.create!(name: 'second', meta: { 'author' => { 'name' => 'Bob' }, 'tags' => %w[ruby], 'stars' => 12 })
end

# Set the SQL apart from the rows printed under it.  The page reads the escape
# and colours the text; a terminal running check-examples does the same.
def red(text)
  "\e[31m#{text}\e[0m"
end

# The statements the examples build run past the width of the pane, which does
# not wrap, so they are broken where SQL itself divides: one clause to a line,
# indented by how deep in parentheses it is.  A CTE or a subquery then reads as
# the nested thing it is rather than as one line to scroll along.  A clause
# still too wide is divided again, at its own commas and before AND and OR.
CLAUSES = %w[
  WITH\ RECURSIVE WITH SELECT FROM WHERE GROUP\ BY HAVING WINDOW ORDER\ BY
  LIMIT OFFSET UNION\ ALL UNION INTERSECT EXCEPT
  INNER\ JOIN LEFT\ OUTER\ JOIN RIGHT\ OUTER\ JOIN FULL\ OUTER\ JOIN
  LEFT\ JOIN RIGHT\ JOIN CROSS\ JOIN JOIN
  INSERT\ INTO UPDATE DELETE\ FROM VALUES SET RETURNING
].freeze
CLAUSE_AT = /\G(?:#{CLAUSES.map { |c| Regexp.escape(c) }.join('|')})(?![A-Z_])/i
CONNECTIVE_AT = /\G(?:AND|OR)\b/i

# Wide enough for the statements here to keep their shape, narrow enough to
# read in the output pane when a table is open beside it and it has half the
# width.
SQL_WIDTH = 72

# A copy with every quoted run blanked out, so the scanning below can use plain
# patterns without a value or an identifier answering for one of them: a column
# named "order", or the word from in 'it''s from me'.  The blanks keep the
# length, so an offset into one is an offset into the other.
def mask_quoted(sql)
  masked = sql.dup
  i = 0
  while i < sql.length
    c = sql[i]
    unless c == "'" || c == '"'
      i += 1
      next
    end
    # Doubled quotes escape the quote, so they are not the end of the run.
    j = i + 1
    while j < sql.length
      if sql[j] == c
        break unless sql[j + 1] == c
        j += 1
      end
      j += 1
    end
    j = sql.length - 1 if j >= sql.length
    masked[i..j] = '.' * (j - i + 1)
    i = j + 1
  end
  masked
end

def format_sql(sql)
  masked = mask_quoted(sql)
  out = +''
  # One entry per open parenthesis: whether a clause was broken inside it,
  # which decides whether its `)` deserves a line of its own or is closing
  # something like COUNT(*), and whether what it follows makes it a clause of
  # its own -- a window's ORDER BY and a filter's WHERE belong to the
  # parentheses they are in rather than to the statement.
  open = []
  newline = lambda do
    out.rstrip!
    out << "\n" << '  ' * open.size unless out.empty?
  end

  i = 0
  while i < sql.length
    case masked[i]
    when '('
      open.push([false, masked[0...i].rstrip.end_with?('OVER', 'FILTER')])
      out << sql[i]
      i += 1
    when ')'
      newline.call if open.pop.first
      out << sql[i]
      i += 1
    else
      # Only at the start of a word: FROM in far_from_here is not a clause.
      at_word_start = i.zero? || masked[i - 1] =~ /[\s(,]/
      if at_word_start && (m = CLAUSE_AT.match(masked, i)) &&
         open.none? {|_, window| window }
        open[-1][0] = true unless open.empty?
        newline.call
        out << sql[i, m[0].length]
        i += m[0].length
      else
        out << sql[i]
        i += 1
      end
    end
  end

  out.each_line.map { |line| divide_clause(line.chomp) }.join("\n")
end

# Only at the top level of the clause: the arguments of a function and the
# innards of an expression are one thing to read and stay on one line.
def divide_clause(line)
  return line if line.length <= SQL_WIDTH

  masked = mask_quoted(line)
  depth = 0
  starts = []
  masked.each_char.with_index do |c, i|
    case c
    when '(' then depth += 1
    when ')' then depth -= 1
    when ',' then starts << i + 1 if depth.zero?
    end
    next unless depth.zero? && i.positive? && masked[i - 1] == ' '
    starts << i if CONNECTIVE_AT.match(masked, i)
  end
  return line if starts.empty?

  indent = line[/\A */] + '  '
  pieces = []
  from = 0
  starts.sort.uniq.each do |start|
    pieces << line[from...start]
    from = start
  end
  pieces << line[from..]

  pieces.each_with_index.map do |piece, n|
    n.zero? ? piece.rstrip : indent + piece.strip
  end.join("\n")
end

# `show` is what the examples call: it prints the SQL a relation builds and then
# the rows it actually returns, so the two can be read side by side.
def show(relation, limit: 20)
  statement = relation.to_sql
  puts red(format_sql(statement))
  puts

  # Read the rows through the connection rather than through the model, so the
  # columns shown are exactly the ones the SELECT asked for.  Going via the
  # model would add its other attributes back as nil.
  print_result ActiveRecord::Base.connection.select_all("#{statement} LIMIT #{limit.to_i}")
  puts
rescue ActiveRecord::StatementInvalid => e
  puts 'The database rejected this query:'
  puts "  #{e.message.lines.first.strip}"
  puts
end

# A statement that changes rows is printed as it runs.  `show` takes a
# relation, and update_all and upsert_all have none to give -- they execute and
# answer with a count -- so their SQL would otherwise be the one thing on this
# page nobody could see.
#
# Only while the page is running what was typed: the schema and the sample data
# are built through these same notifications, and nobody came here to read
# those.
WRITE_STATEMENT = /\A\s*(INSERT|UPDATE|DELETE)\b/i

def show_writes(&block)
  ActiveSupport::Notifications.subscribed(
    method(:print_write), 'sql.active_record', &block)
end

def print_write(*, payload)
  return if %w[SCHEMA TRANSACTION].include?(payload[:name])
  return unless WRITE_STATEMENT.match?(payload[:sql])

  puts red(format_sql(payload[:sql]))
  changed = payload[:affected_rows]
  puts "#{changed} row(s) changed" unless changed.nil?
  puts
end

# Prints just the SQL, for examples where running the query is beside the point.
def sql(relation)
  puts red(format_sql(relation.to_sql))
  puts
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
  name = table_named(table)
  puts name
  puts
  print_result ActiveRecord::Base.connection.select_all("SELECT * FROM #{name} LIMIT #{limit.to_i}")
end

# The same rows as `data`, handed to the page as JSON so it can lay them out
# as a real table.  nil survives the trip as null, which matters here more than
# most places: telling NULL from an empty string is half of what the DSL is
# about.
def data_json(table, limit: 200)
  require 'json'
  result = ActiveRecord::Base.connection.select_all("SELECT * FROM #{table_named(table)} LIMIT #{limit.to_i}")
  rows = cast_rows(result).map { |row| row.map { |value| cell_value(value) } }
  JSON.generate(table: table_named(table), columns: result.columns, rows: rows)
end

# The rows as Ruby values rather than as the adapter left them.  PGlite hands
# every value over as the text PostgreSQL wrote -- on purpose, so that
# ActiveRecord's casting is what decides what a value is -- and a result read
# through the connection rather than through a model has not been cast yet.
# One column is a special case: cast_values flattens it.
def cast_rows(result)
  rows = result.cast_values
  result.columns.one? ? rows.map { |value| [value] } : rows
end

# What a table cell in the page can be given: a number stays a number, so the
# column is recognised as numeric and lines up on the right, and nil stays
# null, so it can be shown as NULL.  Anything with a shape of its own -- a
# JSON document, an array column, a time -- is written out as text, since the
# page has one line per cell to show it in.
def cell_value(value)
  case value
  when nil, true, false, String, Integer, Float then value
  when Hash, Array then JSON.generate(value)
  when BigDecimal then decimal(value)
  else value.to_s
  end
end

# BigDecimal's own way of writing itself is 0.1e3 where the number is 100.0.
# An average is where this turns up: numeric on PostgreSQL and so a decimal,
# where SQLite gives back a float and prints as one.  The same query should
# not look like two different answers.
def decimal(value)
  value.to_s('F')
end

def table_named(table)
  tables.find { |t| t == table.to_s } or
    raise ArgumentError, "no such table: #{table} (#{tables.join(', ')})"
end

# Inspected, so that a string is in quotes and a NULL reads as nil rather than
# as an empty column -- telling the two apart is half of what the DSL is
# about.  A decimal is the exception: see above.
def shown(value)
  value.is_a?(BigDecimal) ? decimal(value) : value.inspect
end

def print_result(result)
  if result.empty?
    puts '(no rows)'
    return
  end

  columns = result.columns
  rows = cast_rows(result).map { |row| row.map {|value| shown(value) } }
  widths = columns.each_with_index.map do |column, i|
    [column.length, *rows.map { |row| row[i].length }].max
  end

  puts columns.each_with_index.map { |c, i| c.ljust(widths[i]) }.join('  ')
  puts widths.map { |w| '-' * w }.join('  ')
  rows.each do |row|
    puts row.each_with_index.map { |v, i| v.ljust(widths[i]) }.join('  ')
  end
  puts
  puts "#{rows.size} row(s)"
end

# Last, so that everything above is defined by the time the schema is built.
# SQLite to start with: it is inside ruby.wasm already, where PostgreSQL is a
# download of its own and is fetched when it is asked for.
use_database('sqlite3')
