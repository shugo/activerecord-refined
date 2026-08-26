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
#   ADAPTER=oracle_enhanced rake test       # Oracle, which only CI provides
#   rake test:all              # all of the above in turn
ADAPTER = ENV.fetch("ADAPTER", "sqlite3")

# Active Record 8.1 knows an adapter only once its gem is loaded, and the
# oracle_enhanced gem (with its Instant Client build) is installed only for
# this adapter's run -- so it is required here, not through Bundler.require.
require "active_record/connection_adapters/oracle_enhanced_adapter" if ADAPTER == "oracle_enhanced"
require "active_record/connection_adapters/sqlserver_adapter" if ADAPTER == "sqlserver"

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
  when "oracle_enhanced"
    # database is the service name; unlike the others there is no schema-less
    # account to fall back on, so the user and password are required, and the
    # suite connects straight to a schema that already exists.
    {
      adapter: "oracle_enhanced",
      host: ENV.fetch("DB_HOST", "127.0.0.1"),
      port: ENV["DB_PORT"]&.to_i,
      database: ENV.fetch("DB_DATABASE", "FREEPDB1"),
      username: ENV.fetch("DB_USERNAME"),
      password: ENV.fetch("DB_PASSWORD"),
    }
  when "sqlserver"
    {
      adapter: "sqlserver",
      host: ENV.fetch("DB_HOST", "127.0.0.1"),
      port: ENV["DB_PORT"]&.to_i,
      username: ENV.fetch("DB_USERNAME"),
      password: ENV.fetch("DB_PASSWORD"),
      database: DATABASE_NAME,
    }
  else
    raise ArgumentError, "unknown ADAPTER: #{ADAPTER}"
  end

# PostgreSQL, the MySQL family and SQL Server keep their databases between
# runs, so create one on first use.  SQLite is in memory and Oracle connects
# to a schema that already exists, so neither goes through this.
if ADAPTER == "postgresql" || MYSQL_ADAPTERS.include?(ADAPTER) || ADAPTER == "sqlserver"
  maintenance_database =
    case ADAPTER
    when "postgresql" then "postgres"
    when "sqlserver" then "master"
    else "mysql"
    end
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

  # oracle_enhanced does not implement upsert_all at all -- not the conflict
  # target, the statement itself.
  def skip_without_upsert
    skip "#{ADAPTER} has no upsert" if oracle? || sqlserver?
  end

  # JSON containment: PostgreSQL has @>, MySQL JSON_CONTAINS, and neither
  # SQLite nor Oracle a way the gem generalises to an arbitrary value.
  def skip_without_json_containment
    skip "#{ADAPTER} has no JSON containment" if sqlite? || oracle? || sqlserver?
  end

  # Oracle has no JSON_KEYS, and reaching the keys through JSON_TABLE is not
  # written yet.
  def skip_without_json_keys
    skip "#{ADAPTER} has no JSON keys function" if oracle? || sqlserver?
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
    mariadb? || oracle? || sqlserver? ? JSON.generate(hash) : hash
  end

  # SQL Server 2022 has JSON_ARRAY and JSON_OBJECT, but building one from a
  # dug scalar needs a scalar JSON_QUERY it has no ALLOW SCALARS for, and it
  # has no JSON aggregate at all.
  def skip_without_json_build
    skip "#{ADAPTER} cannot build JSON from a dug value here" if sqlserver?
  end

  def skip_without_json_aggregate
    skip "#{ADAPTER} has no JSON aggregate" if sqlserver?
  end

  # How each adapter spells a cast to a whole number: MySQL casts to SIGNED
  # and has no integer at all, PostgreSQL the other way about, SQLite either.
  def integer_type
    mysql? ? "signed" : "integer"
  end

  def sqlite?
    ADAPTER == "sqlite3"
  end

  def mysql?
    MYSQL_ADAPTERS.include?(ADAPTER)
  end

  def oracle?
    ADAPTER == "oracle_enhanced"
  end

  def sqlserver?
    ADAPTER == "sqlserver"
  end

  def mariadb?
    mysql? && ActiveRecord::Base.connection.mariadb?
  end

  # GROUPING SETS, ROLLUP and CUBE are PostgreSQL's; MySQL has only WITH
  # ROLLUP, which carries rollup and only rollup, and SQLite has none.
  def skip_without_grouping_sets
    skip "#{ADAPTER} has no GROUPING SETS" unless ADAPTER == "postgresql"
  end

  # Oracle has ROLLUP, but Arel's oracle_enhanced visitor cannot write the
  # node, so the gem does not offer it there yet.
  def skip_without_rollup
    skip "#{ADAPTER} has no ROLLUP" if sqlite? || oracle? || sqlserver?
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
    skip "#{ADAPTER} has no ANY or ALL" if sqlite?
  end

  # BIT_AND, BIT_OR and BIT_XOR are PostgreSQL's and MySQL's; neither SQLite
  # nor Oracle has the three, nor BIT_COUNT.
  def skip_without_bit_aggregates
    skip "#{ADAPTER} has no bit aggregates" if sqlite? || oracle? || sqlserver?
  end

  def skip_without_array_columns
    skip "#{ADAPTER} has no array columns" unless ADAPTER == "postgresql"
  end

  # MySQL has no NULLS FIRST/LAST; Arel emulates it with a leading IS NULL
  # ordering, so only the resulting order is portable, not the SQL.
  def skip_without_nulls_ordering_syntax
    skip "#{ADAPTER} emulates NULLS FIRST/LAST" if mysql? || sqlserver?
  end

  def regexp_operator
    Regexp.escape(REGEXP_OPERATORS.fetch(ADAPTER).first)
  end

  def not_regexp_operator
    Regexp.escape(REGEXP_OPERATORS.fetch(ADAPTER).last)
  end

  # MySQL quotes identifiers with backticks instead of double quotes, and
  # doubles the backslashes inside string literals because backslash is itself
  # an escape character there.  Oracle folds an unquoted identifier to upper
  # case, so it quotes the columns back as "USERS"."AGE" where the others
  # keep "users"."age".  Normalising all three lets a single expectation
  # cover every adapter; values sit in single quotes and keywords outside
  # quotes, so lowering only what is inside double quotes leaves them alone.
  def normalize_sql(sql)
    sql = sql.tr("`", '"').gsub("\\\\") { "\\" }
    # SQL Server quotes identifiers in [brackets]; string literals are in
    # single quotes, so what is bracketed is always an identifier.  It also
    # marks a string literal national with a leading N -- N'x' -- which the
    # \b keeps to the prefix, off an N inside a value.
    if sqlserver?
      sql = sql.gsub(/\[([^\]]*)\]/, '"\1"').gsub(/\bN'/, "'")
    end
    # Oracle folds a name to upper case only when it was written unquoted, and
    # preserves one quoted with case of its own -- an alias like "postCount".
    # So lower only the all-upper tokens; leave anything with a lower-case
    # letter, which was quoted deliberately, as written.
    sql = sql.gsub(/"[^"]*"/) { |name| name.match?(/[a-z]/) ? name : name.downcase } if oracle?
    sql
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
      # Oracle's native JSON type is one ruby-oci8 cannot fetch (datatype
      # 119), so the document is kept in a CLOB as text; Oracle's JSON
      # functions read and write JSON in a CLOB just the same.
      if ADAPTER == "postgresql"
        t.jsonb(:meta)
      elsif ADAPTER == "oracle_enhanced"
        t.text(:meta)
      else
        t.json(:meta)
      end
    end
  end
end
ActiveRecord::Migration.verbose = false
CreateAllTables.new.up
