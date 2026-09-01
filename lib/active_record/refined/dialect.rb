# frozen_string_literal: true

require "concurrent/map"

module ActiveRecord
  module Refined
    # One class per family of SQL spellings, resolved from the model's adapter
    # and asked, rather than branched on, for whatever a query builds
    # differently from one database to the next.  The base is the standard
    # spelling an unclassified adapter keeps; each subclass overrides only
    # where its family departs from it.  Where no spelling is anyone's
    # standard -- most of JSON -- the base refuses instead, and every family
    # carries its own.
    #
    # The families are loaded as they are met: an application on PostgreSQL
    # never loads the Oracle class, whose adapter it will never resolve to.
    class Dialect
      autoload :MysqlishJsonFunctions,
               "active_record/refined/dialect/mysqlish_json_functions"
      autoload :Sqlite, "active_record/refined/dialect/sqlite"
      autoload :Postgresql, "active_record/refined/dialect/postgresql"
      autoload :MysqlCompat, "active_record/refined/dialect/mysql_compat"
      autoload :Mysql, "active_record/refined/dialect/mysql"
      autoload :Mariadb, "active_record/refined/dialect/mariadb"
      autoload :Oracle, "active_record/refined/dialect/oracle"
      autoload :SqlServer, "active_record/refined/dialect/sql_server"

      # One instance per family, shared across threads.  The dialect carries no
      # state, so sharing is safe; the map is a concurrent one so that building
      # the instance the first time is too, on a Ruby whose threads run in
      # parallel as much as on one whose do not.
      @instances = Concurrent::Map.new

      @registry = Concurrent::Map.new

      class << self
        # Names an adapter's dialect.  An adapter's gem, or an application,
        # registers its own -- a Dialect subclass overriding only where its
        # family departs from the standard:
        #
        #   ActiveRecord::Refined::Dialect.register("exampledb", ExampleDialect)
        #
        # A block registers an adapter whose dialect only the connection can
        # name, as mysql2's is either MySQL's or MariaDB's: it receives the
        # model and returns the class.  The built-in families register with
        # blocks too, which is what leaves each autoloaded until an adapter
        # first resolves to it.
        def register(adapter, dialect = nil, &block)
          unless dialect || block
            raise ArgumentError, "register takes a dialect class or a block"
          end
          @registry[adapter.to_s] = dialect || block
        end

        # The dialect a model's queries are built for.  An adapter nobody has
        # registered keeps the standard spellings and is left to say for
        # itself what it cannot do.  The instances are cached by class rather
        # than by adapter, so a re-registration takes effect on the next
        # query.
        def for(model)
          klass = class_for(model.connection_db_config.adapter, model)
          @instances.compute_if_absent(klass) { klass.new }
        end

        private
          def class_for(adapter, model)
            entry = @registry[adapter] or return Dialect
            entry.is_a?(Proc) ? entry.call(model) : entry
          end
      end

      register("sqlite3") { Sqlite }
      register("postgresql") { Postgresql }
      register("postgis") { Postgresql }
      register("pglite") { Postgresql }
      # MariaDB and MySQL answer to one adapter apiece and part company only
      # at the connection, so those two are told apart by asking it.
      %w[mysql2 trilogy].each do |adapter|
        register(adapter) do |model|
          model.with_connection { |connection| connection.mariadb? } ? Mariadb : Mysql
        end
      end
      register("oracle_enhanced") { Oracle }
      register("sqlserver") { SqlServer }

      # --- Capabilities.  The standard has them; a family without one says so
      #     by overriding to false, and the block raises where it is asked for.

      # The scalar and datetime functions a family spells differently, or has
      # none of.  A name it does not list it spells like the method, upper
      # cased; a nil says it has no equivalent, and the block raises.  The
      # base -- an unclassified adapter -- keeps the names most families
      # share and nils the ones that are one or two families' own: printf
      # FORMAT, whose name MySQL hands to a different function entirely,
      # RAND, DATE_TRUNC, NOW, LOG2 and the three bit aggregates.  A family
      # that has one of them says so in a table of its own, since the tables
      # shadow rather than merge.
      FUNCTIONS = {
        format: nil, rand: nil, date_trunc: nil, now: nil, log2: nil,
        bit_and: nil, bit_or: nil, bit_xor: nil,
      }.freeze

      # The name this family spells a function with, asked for as the block
      # builds the call; {FUNCTIONS} is where the answer is looked up.
      # @param name [Symbol] the method's own name, as {BlockContext} has it
      # @return [String]
      # @raise [NotImplementedError] where the family has no equivalent
      def function_name(name, model)
        functions = self.class::FUNCTIONS
        return name.to_s.upcase unless functions.key?(name)
        functions.fetch(name) ||
          raise(NotImplementedError,
                "#{name} has no equivalent on #{model.connection_db_config.adapter}")
      end

      # Whether the datetime value functions take a precision,
      # `current_timestamp(3)`.  SQLite and SQL Server take none.
      def datetime_precision_supported? = true

      # Whether the family has EXTRACT.  SQLite spells the fields as strftime
      # formats and SQL Server as DATEPART, so neither answers to the name.
      def extract_supported? = true

      # Whether a comparison can be quantified with ANY or ALL.  SQLite has
      # neither.
      def quantifiers_supported? = true

      # Whether a FULL OUTER JOIN can be written.  The MySQL family has none.
      def full_outer_join_supported? = true

      # The FILTER clause, which restricts an aggregate to the rows a condition
      # holds for.  A family without it gets the CASE that means the same,
      # built by the aggregate node.
      def filter_supported? = true

      # The bitwise operators, & | ^ << >> and ~.  No SQL standard has them,
      # so unlike the capabilities above the base refuses and each family
      # that has the operators says so itself -- which of the seven is every
      # one but Oracle, whose single bit operation is the BITAND function.
      def bitwise_operators_supported? = false

      # The array comparisons -- @>, <@ and && against an array column.
      # The type and its operators are PostgreSQL's alone.
      def array_comparisons_supported? = false

      # A lateral join is allowed to stand unless the family refuses it here.
      def check_lateral(_model); end

      # --- Expressions built differently per family.

      # BIT_COUNT of a number.  The standard has no equivalent; the families
      # that do override.
      def bit_count(_expr, model)
        raise NotImplementedError,
          "bit_count has no equivalent on #{model.connection_db_config.adapter}"
      end

      # The row an upsert could not insert.  `excluded` is PostgreSQL's name
      # for it, which SQLite took over and the MySQL family spells
      # VALUES(column), so each of the three carries its own; the families
      # without an upsert have nothing for the name to stand in.
      def excluded(_column, model)
        raise NotImplementedError,
          "excluded has no equivalent on #{model.connection_db_config.adapter}"
      end

      # true? / false? and their negations.  The standard spells them with the
      # boolean IS [NOT] TRUE/FALSE, which keeps a NULL out of the plain form
      # and in of the negation; a family without a boolean type overrides.
      def truth_value(operand, value, negated, _model)
        literal = value ? Arel::Nodes::True.new : Arel::Nodes::False.new
        Arel::Nodes::InfixOperation.new(negated ? "IS NOT" : "IS", operand, literal)
      end

      # COLLATE, which every family spells `expr COLLATE name` -- the name a
      # bare identifier, no Arel node for it.  Written bare it has to be a
      # plain one, so it is checked here; PostgreSQL quotes it and widens what
      # it takes, overriding.  PostgreSQL also folds an unquoted name to lower
      # case, where its built-in names are upper -- "C", "POSIX" -- another
      # reason it quotes rather than inheriting this.
      def collate(operand, name, _model)
        AST.check_name(name, AST::COLLATION_NAME, "collation name")
        Arel::Nodes::InfixOperation.new(
          "COLLATE", operand, Arel::Nodes::SqlLiteral.new(name))
      end

      # A date moved by a duration: `:due_on + 3.days`.  The standard adds an
      # interval literal, `x + INTERVAL '3' DAY`, which PostgreSQL and the
      # MySQL family both read; SQLite, SQL Server and Oracle each spell the
      # move their own way and override.  The amount is a whole number and
      # the unit one of six names, both checked by the node, so both are
      # written into the SQL as they are.  date_only says the operand is a
      # date rather than a datetime, which only SQLite has to be told.
      def add_interval(date, amount, unit, subtract, _date_only)
        interval = Arel::Nodes::SqlLiteral.new("INTERVAL '#{amount}' #{unit.to_s.upcase}")
        Arel::Nodes::Grouping.new(
          Arel::Nodes::InfixOperation.new(subtract ? :- : :+, date, interval))
      end

      # XOR, which no two families spell alike.  The default is the two
      # operations it is made of, naming each operand twice -- built only
      # from the & and | a family has just claimed through
      # {#bitwise_operators_supported?}, so wherever it can be reached at
      # all it works.  Of the five that claim them, SQLite alone keeps it;
      # the rest have an operator of their own and override.
      def bitwise_xor(left, right)
        Arel::Nodes::Subtraction.new(
          Arel::Nodes::Grouping.new(Arel::Nodes::BitwiseOr.new(left, right)),
          Arel::Nodes::Grouping.new(Arel::Nodes::BitwiseAnd.new(left, right)))
      end

      # --- Reading JSON.  No two families spell it alike and the standard
      #     names only part of it, so the base refuses each piece and every
      #     family carries its own; what an unclassified adapter would get
      #     from any one family's spelling is a query that means nothing on
      #     the next.

      # dig / dig_text.  Nothing reaches every family: SQLite and PostgreSQL
      # have operators of their own, MySQL its functions, and the two that
      # spell it as SQL:2016's JSON_VALUE and JSON_QUERY -- Oracle and SQL
      # Server -- differ over what a scalar leaf comes back as.  Every
      # family overrides.
      def json_path(_document, _dollar_path, _steps, _json_value, model)
        raise NotImplementedError,
          "dig has no equivalent on #{model.connection_db_config.adapter}"
      end

      # A Ruby value on the JSON side of a comparison belongs to a JSON type;
      # a family without one refuses it.
      def json_literal(_json, model)
        raise NotImplementedError,
          "a JSON comparison has no equivalent on " \
          "#{model.connection_db_config.adapter}; dig_text gives the value"
      end

      # contains?: whether the document holds what is given.  The standard has
      # no equivalent; PostgreSQL has @> and the MySQL family JSON_CONTAINS,
      # and both override.
      def json_contains(_document, _json, model)
        raise NotImplementedError,
          "contains? has no equivalent on #{model.connection_db_config.adapter}"
      end

      # key?: whether the object has the key.  SQL:2016 spells it
      # JSON_EXISTS, which of the five only Oracle answers to; PostgreSQL has
      # the ? operator, the MySQL family JSON_CONTAINS_PATH, SQLite json_type
      # at the path and SQL Server JSON_PATH_EXISTS, so every family
      # overrides.
      #
      # The key arrives spelled both ways -- bare in `name`, as a $ path in
      # `path` -- since a family reads it as one or as the other.
      def json_has_key(_document, _name, _path, model)
        raise NotImplementedError,
          "key? has no equivalent on #{model.connection_db_config.adapter}"
      end

      # keys: the keys of an object as a JSON array.  JSON_KEYS is the MySQL
      # family's own; SQLite and PostgreSQL gather theirs through a subquery
      # over their key-listing functions, and Oracle and SQL Server would
      # reach them only through table unnests not written here.
      def json_keys(_document, model)
        raise NotImplementedError,
          "keys has no equivalent on #{model.connection_db_config.adapter}"
      end

      # --- Writing JSON.  A Ruby document or boolean has to be told apart from
      #     a bare scalar, and embedded as the JSON it spells.

      # The test the writing hooks share: a Hash, an Array or a boolean is a
      # document, and anything else a bare scalar.
      def json_document_value?(value)
        value.is_a?(::Hash) || value.is_a?(::Array) || value == true || value == false
      end

      # A Ruby document or boolean written where one of the JSON functions
      # wants JSON.  Every family marks the literal its own way --
      # JSON_EXTRACT($) on MySQL, json() on SQLite, FORMAT JSON on Oracle,
      # JSON_QUERY on SQL Server -- and none of the marks is another's.
      def json_argument(_value, model)
        raise NotImplementedError,
          "a document written as JSON has no equivalent on " \
          "#{model.connection_db_config.adapter}"
      end

      # bury: setting a value at a path.  The standard has no editing
      # functions at all: JSON_SET is {MysqlishJsonFunctions}', jsonb_set
      # PostgreSQL's, JSON_TRANSFORM Oracle's and JSON_MODIFY SQL Server's.
      def json_set(_document, _steps, _dollar_path, _value, _expression, model)
        raise NotImplementedError,
          "bury has no equivalent on #{model.connection_db_config.adapter}"
      end

      # except: removing keys, for which the standard likewise has nothing.
      # {MysqlishJsonFunctions} removes a path apiece with JSON_REMOVE,
      # PostgreSQL subtracts an array of keys, Oracle and SQL Server edit
      # through JSON_TRANSFORM and JSON_MODIFY.
      def json_remove(_document, _dollar_paths, _steps, model)
        raise NotImplementedError,
          "except has no equivalent on #{model.connection_db_config.adapter}"
      end

      # json_array / json_object built in the row.  JSON_ARRAY(a, b) is
      # SQL:2016, but JSON_OBJECT is where the syntaxes part -- the standard
      # pairs each key as KEY k VALUE v, {MysqlishJsonFunctions} alternates
      # them, SQL Server writes k : v -- so the pair travels together and
      # each family says its own; SQL Server's is not written here yet.
      def json_build(kind, _keys, _args, model)
        raise NotImplementedError,
          "json_#{kind} has no equivalent on #{model.connection_db_config.adapter}"
      end

      # A document or boolean built into json_array/json_object.  The default
      # rides through {#json_argument}, and refuses or serves with it;
      # PostgreSQL casts to jsonb and overrides.
      def json_build_argument(value, model)
        json_argument(value, model)
      end

      # json_arrayagg / json_objectagg gather rows into a document.  The
      # names are SQL:2016's own, which the MySQL family and Oracle answer
      # to, so unlike the rest of JSON the base keeps them; SQLite and
      # PostgreSQL have names of their own, and SQL Server, which has no
      # JSON aggregates, refuses.
      def json_aggregate_name(kind)
        kind == :arrayagg ? "JSON_ARRAYAGG" : "JSON_OBJECTAGG"
      end

      # These two keep a NULL as JSON null rather than passing over it, so the
      # CASE that stands in for FILTER would leave one in the document; a
      # family without FILTER for them refuses it.
      def json_aggregate_filter_supported? = true

      # A family that cannot take these two as window functions refuses one.
      def check_json_aggregate_window(_source, _model); end

      # string_agg: the strings of a group joined into one.  The standard's is
      # LISTAGG(x, ', ') WITHIN GROUP (ORDER BY ...), which Oracle reads, and
      # the ORDER BY is not optional there: an aggregate asked for no order
      # is given the values' own, which costs the caller nothing to have.
      # PostgreSQL and SQLite carry the ORDER BY inside the call, SQL Server
      # takes the WITHIN GROUP only when there is an order, and the MySQL
      # family has GROUP_CONCAT; every one of them overrides.  `string` says
      # the operand is a column declared one, which PostgreSQL alone asks.
      def string_agg(operand, separator, orders, _string, model)
        orders = [operand] if orders.empty?
        Arel.sql("LISTAGG(#{compile(operand, model)}, #{quote(separator, model)}) " \
                 "WITHIN GROUP (ORDER BY #{compile_list(orders, model)})")
      end

      # A family that cannot take string_agg as a window function refuses one.
      def check_string_aggregate_window(_model); end

      # A JSON value in an IN list or a range is compared per element on the
      # MySQL family, which overrides; the standard leaves it to the IN.
      def json_list_by_element? = false

      # --- Grouping.  GROUPING SETS, ROLLUP and CUBE, which the standard has
      #     none of; PostgreSQL has all three and the MySQL family rollup alone.

      # Whether the family has the kind of grouping asked for, one of
      # `:grouping_sets`, `:rollup` and `:cube`.
      def grouping_supported?(_kind) = false

      # The MySQL family spells rollup WITH ROLLUP, trailing the group list
      # rather than wrapping a list of its own, and overrides.
      def grouping_by_with_rollup? = false

      protected
        # The values of JSON_ARRAY as they are, JSON_OBJECT's keys
        # alternating with theirs -- the shape MysqlishJsonFunctions and
        # PostgreSQL's jsonb_build_* pair both take.
        def json_build_body(kind, keys, args)
          return args if kind == :array
          keys.zip(args).flat_map { |key, arg| [Arel::Nodes.build_quoted(key), arg] }
        end

        # The name(x, ', ' ORDER BY ...) shape of string_agg, PostgreSQL's and
        # SQLite's; a node while there is no order, since Arel has one for
        # that much.
        def string_agg_call(name, operand, separator, orders, model)
          if orders.empty?
            return Arel::Nodes::NamedFunction.new(
              name, [operand, Arel::Nodes.build_quoted(separator)])
          end
          Arel.sql("#{name}(#{compile(operand, model)}, #{quote(separator, model)} " \
                   "ORDER BY #{compile_list(orders, model)})")
        end

        # The connection's own visitor and quoting, for the families that write
        # a call out because its grammar no Arel node carries.
        def compile(node, model)
          model.with_connection { |connection| connection.visitor.compile(node) }
        end

        def compile_list(nodes, model)
          model.with_connection do |connection|
            nodes.map { |node| connection.visitor.compile(node) }.join(", ")
          end
        end

        def quote(value, model)
          model.with_connection { |connection| connection.quote(value) }
        end
    end
  end
end
