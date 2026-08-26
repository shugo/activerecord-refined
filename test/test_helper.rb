# frozen_string_literal: true

$LOAD_PATH.unshift(File.join(File.dirname(__FILE__), "..", "lib"))
$LOAD_PATH.unshift(File.dirname(__FILE__))

require "minitest/autorun"
Bundler.require

require "active_record"
require "etc"
require "json"

# Which database to generate SQL for.  The tests only build queries, so any
# server reachable without further setup will do; the devcontainer runs
# PostgreSQL and MariaDB on localhost with a passwordless account named after
# the container user.
#
#   rake test                  # sqlite3
#   ADAPTER=postgresql rake test
#   ADAPTER=mysql2 rake test                # MariaDB, on 3306
#   ADAPTER=trilogy rake test               # the same server through Trilogy
#   ADAPTER=mysql2 DB_PORT=3307 rake test   # MySQL, where the devcontainer
#                                           # serves it (rake test:mysql8)
#   rake test:all              # all of the above in turn
ADAPTER = ENV.fetch("ADAPTER", "sqlite3")

# Trilogy and mysql2 both reach the MySQL family of servers -- the same
# MySQL and MariaDB -- and so want the same spellings throughout; mariadb?
# tells that pair of servers apart where they disagree.
MYSQL_ADAPTERS = %w[mysql2 trilogy].freeze

DATABASE_NAME = "activerecord_refined_test"

DATABASE_CONFIG =
  case ADAPTER
  when "sqlite3"
    { adapter: "sqlite3", database: ":memory:" }
  when "postgresql", *MYSQL_ADAPTERS
    {
      adapter: ADAPTER,
      host: ENV.fetch("DB_HOST", "127.0.0.1"),
      port: ENV["DB_PORT"]&.to_i,
      # getlogin comes back nil in the devcontainer, where there is no
      # controlling terminal.  mysql2 and pg fill an absent name with the
      # process's own user, but trilogy sends root and is refused, so the
      # name is resolved here to the container user either client wants.
      username: ENV.fetch("DB_USERNAME") { Etc.getlogin || Etc.getpwuid.name },
      password: ENV["DB_PASSWORD"],
      database: DATABASE_NAME,
    }
  else
    raise ArgumentError, "unknown ADAPTER: #{ADAPTER}"
  end

# The server databases persist between runs, so create one on first use.
unless ADAPTER == "sqlite3"
  maintenance_database = ADAPTER == "postgresql" ? "postgres" : "mysql"
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
    "postgresql" => ["~", "!~"],
    **MYSQL_ADAPTERS.to_h { |adapter| [adapter, ["REGEXP", "NOT REGEXP"]] },
  }.freeze

  def skip_without_regexp_support
    skip "#{ADAPTER} has no regexp operator" unless REGEXP_OPERATORS.key?(ADAPTER)
  end

  # upsert_all wants to be told which unique index it is upserting against,
  # except on MySQL, which does not accept being told.
  def upsert_target
    mysql? ? {} : { unique_by: :page }
  end

  # JSON containment: PostgreSQL has @>, MySQL JSON_CONTAINS, SQLite neither.
  def skip_without_json_containment
    skip "#{ADAPTER} has no JSON containment" if ADAPTER == "sqlite3"
  end

  # Comparing a JSON value with a Ruby one is for jsonb and MySQL's JSON
  # type; SQLite and MariaDB have only the text.
  def skip_without_json_comparisons
    return if ADAPTER == "postgresql"
    return if mysql? && !mariadb?
    skip "#{mariadb? ? 'MariaDB' : ADAPTER} has no JSON comparison"
  end

  # MySQL is the one without a FULL OUTER JOIN, and so is MariaDB.
  def skip_without_full_outer_joins
    skip "#{ADAPTER} has no full outer join" if mysql?
  end

  # MariaDB's json is a checked longtext, which Active Record sees as a string
  # and does not serialise a hash into -- what would go in is Ruby's inspect,
  # which the check refuses.  MySQL's json is a type of its own and takes the
  # hash; handing that one a string would store the document as a JSON string
  # rather than as the object, and every path would find nothing.  Both answer
  # to the mysql2 adapter, so the two have to be told apart.
  def json_document(hash)
    mariadb? ? JSON.generate(hash) : hash
  end

  # How each adapter spells a cast to a whole number: MySQL casts to SIGNED
  # and has no integer at all, PostgreSQL the other way about, SQLite either.
  def integer_type
    mysql? ? "signed" : "integer"
  end

  def mysql?
    MYSQL_ADAPTERS.include?(ADAPTER)
  end

  def mariadb?
    mysql? && ActiveRecord::Base.connection.mariadb?
  end

  # GROUPING SETS, ROLLUP and CUBE are PostgreSQL's; MySQL has only WITH
  # ROLLUP, which carries rollup and only rollup, and SQLite has none.
  def skip_without_grouping_sets
    skip "#{ADAPTER} has no GROUPING SETS" unless ADAPTER == "postgresql"
  end

  def skip_without_rollup
    skip "#{ADAPTER} has no ROLLUP" if ADAPTER == "sqlite3"
  end

  # LATERAL is PostgreSQL's and MySQL 8's; MariaDB and SQLite have none.
  def skip_without_lateral
    return if ADAPTER == "postgresql"
    skip "#{mariadb? ? 'MariaDB' : ADAPTER} has no LATERAL" if !mysql? || mariadb?
  end

  # DISTINCT ON is PostgreSQL's; Arel refuses to write it for the others.
  def skip_without_distinct_on
    skip "#{ADAPTER} has no DISTINCT ON" unless ADAPTER == "postgresql"
  end

  # ANY and ALL over a subquery are PostgreSQL's and MySQL's alike; SQLite
  # has neither quantifier.
  def skip_without_quantifiers
    skip "#{ADAPTER} has no ANY or ALL" if ADAPTER == "sqlite3"
  end

  # BIT_AND, BIT_OR and BIT_XOR are PostgreSQL's and MySQL's; SQLite has
  # none of the three, nor BIT_COUNT.
  def skip_without_bit_aggregates
    skip "#{ADAPTER} has no bit aggregates" if ADAPTER == "sqlite3"
  end

  def skip_without_array_columns
    skip "#{ADAPTER} has no array columns" unless ADAPTER == "postgresql"
  end

  # MySQL has no NULLS FIRST/LAST; Arel emulates it with a leading IS NULL
  # ordering, so only the resulting order is portable, not the SQL.
  def skip_without_nulls_ordering_syntax
    skip "#{ADAPTER} emulates NULLS FIRST/LAST" if mysql?
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
    sql.tr("`", '"').gsub("\\\\") { "\\" }
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

# Self-referencing, for the recursive CTE tests.
class Node < ActiveRecord::Base
end

# For the writing statements, which need something to conflict with.
class Tally < ActiveRecord::Base
end

# For the JSON tests; see json_document for how the two MySQLs differ.
class Doc < ActiveRecord::Base
end

class CreateAllTables < ActiveRecord::Migration[8.1]
  def up
    drop_table(:users, if_exists: true)
    drop_table(:authors, if_exists: true)
    drop_table(:posts, if_exists: true)
    drop_table(:nodes, if_exists: true)
    drop_table(:tallies, if_exists: true)
    drop_table(:docs, if_exists: true)
    create_table(:users) do |t|
      t.string :name
      t.integer :age
      t.boolean :active
      t.integer :flags
      t.string :tags, array: true if ADAPTER == "postgresql"
    end
    create_table(:authors) { |t| t.string :name }
    create_table(:posts) { |t| t.string :title; t.integer :author_id }
    create_table(:nodes) { |t| t.string :name; t.integer :parent_id }
    create_table(:tallies) do |t|
      t.string :page
      t.integer :hits
      t.index :page, unique: true
    end
    create_table(:docs) do |t|
      t.string :name
      ADAPTER == "postgresql" ? t.jsonb(:meta) : t.json(:meta)
    end
  end
end
ActiveRecord::Migration.verbose = false
CreateAllTables.new.up
