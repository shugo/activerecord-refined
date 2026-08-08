$LOAD_PATH.unshift(File.join(File.dirname(__FILE__), '..', 'lib'))
$LOAD_PATH.unshift(File.dirname(__FILE__))

require 'minitest/autorun'
Bundler.require

require 'active_record'
require 'etc'

# Which database to generate SQL for.  The tests only build queries, so any
# server reachable without further setup will do; the devcontainer runs
# PostgreSQL and MariaDB on localhost with a passwordless account named after
# the container user.
#
#   rake test                  # sqlite3
#   ADAPTER=postgresql rake test
#   ADAPTER=mysql2 rake test
#   rake test:all              # all three in turn
ADAPTER = ENV.fetch('ADAPTER', 'sqlite3')

DATABASE_NAME = 'activerecord_refined_test'.freeze

DATABASE_CONFIG =
  case ADAPTER
  when 'sqlite3'
    {adapter: 'sqlite3', database: ':memory:'}
  when 'postgresql', 'mysql2'
    {
      adapter: ADAPTER,
      host: ENV.fetch('DB_HOST', '127.0.0.1'),
      username: ENV.fetch('DB_USERNAME') { Etc.getlogin },
      password: ENV['DB_PASSWORD'],
      database: DATABASE_NAME,
    }
  else
    raise ArgumentError, "unknown ADAPTER: #{ADAPTER}"
  end

# The server databases persist between runs, so create one on first use.
unless ADAPTER == 'sqlite3'
  maintenance_database = ADAPTER == 'postgresql' ? 'postgres' : 'mysql'
  ActiveRecord::Base.establish_connection(
    DATABASE_CONFIG.merge(database: maintenance_database))
  begin
    ActiveRecord::Base.lease_connection.create_database(DATABASE_NAME)
  rescue ActiveRecord::DatabaseAlreadyExists
  end
  ActiveRecord::Base.remove_connection
end

ActiveRecord::Base.establish_connection(DATABASE_CONFIG)

module SqlAssertions
  # Arel spells the regexp match differently per adapter, and raises on the
  # ones missing from this list.
  REGEXP_OPERATORS = {
    'postgresql' => ['~', '!~'],
    'mysql2' => ['REGEXP', 'NOT REGEXP'],
  }.freeze

  def skip_without_regexp_support
    skip "#{ADAPTER} has no regexp operator" unless REGEXP_OPERATORS.key?(ADAPTER)
  end

  def skip_without_array_columns
    skip "#{ADAPTER} has no array columns" unless ADAPTER == 'postgresql'
  end

  def regexp_operator
    Regexp.escape(REGEXP_OPERATORS.fetch(ADAPTER).first)
  end

  def not_regexp_operator
    Regexp.escape(REGEXP_OPERATORS.fetch(ADAPTER).last)
  end

  # MySQL quotes identifiers with backticks instead of double quotes, and
  # doubles the backslashes inside string literals because backslash is itself
  # an escape character there.  Normalising both lets a single expectation
  # cover every adapter.
  def normalize_sql(sql)
    sql.tr('`', '"').gsub("\\\\") { "\\" }
  end

  # Takes a relation or the SQL string of one.
  def assert_sql(pattern, relation_or_sql)
    sql = relation_or_sql.respond_to?(:to_sql) ? relation_or_sql.to_sql : relation_or_sql
    assert_match(pattern, normalize_sql(sql))
  end
end

class Minitest::Test
  include SqlAssertions
end

class User < ActiveRecord::Base
end

class Author < ActiveRecord::Base
  has_many :posts
end

class Post < ActiveRecord::Base
  belongs_to :author
end

class CreateAllTables < ActiveRecord::Migration[8.1]
  def up
    drop_table(:users, if_exists: true)
    drop_table(:authors, if_exists: true)
    drop_table(:posts, if_exists: true)
    create_table(:users) do |t|
      t.string :name
      t.integer :age
      t.string :tags, array: true if ADAPTER == 'postgresql'
    end
    create_table(:authors) {|t| t.string :name}
    create_table(:posts) {|t| t.string :title; t.integer :author_id}
  end
end
ActiveRecord::Migration.verbose = false
CreateAllTables.new.up
