# frozen_string_literal: true

module ActiveRecord
  module Refined
    # One class per family of SQL spellings, resolved from the model's adapter
    # and asked, rather than branched on, for whatever a query builds
    # differently from one database to the next.  The base is the standard
    # spelling an unclassified adapter keeps; each subclass overrides only
    # where its family departs from it.
    #
    # The families are loaded as they are met: an application on PostgreSQL
    # never loads the Oracle class, whose adapter it will never resolve to.
    class Dialect
      autoload :Sqlite, "active_record/refined/dialect/sqlite"
      autoload :Postgresql, "active_record/refined/dialect/postgresql"
      autoload :MysqlCompat, "active_record/refined/dialect/mysql_compat"
      autoload :Mysql, "active_record/refined/dialect/mysql"
      autoload :Mariadb, "active_record/refined/dialect/mariadb"
      autoload :Oracle, "active_record/refined/dialect/oracle"

      class << self
        # The dialect a model's queries are built for.  MariaDB and MySQL
        # answer to one adapter apiece and part company only at the connection,
        # so those two are told apart by asking it; the rest go by adapter name
        # alone.  The dialect carries no state, so one instance serves a whole
        # adapter, cached here on first use.
        def for(model)
          adapter = model.connection_db_config.adapter
          (@instances ||= {})[adapter] ||= resolve(adapter, model).new
        end

        private
          def resolve(adapter, model)
            case adapter
            when "sqlite3" then Sqlite
            when "postgresql", "postgis", "pglite" then Postgresql
            when "mysql2", "trilogy"
              model.with_connection { |connection| connection.mariadb? } ? Mariadb : Mysql
            when "oracle_enhanced" then Oracle
            else Dialect
            end
          end
      end

      # --- Capabilities.  The standard has them; a family without one says so
      #     by overriding to false, and the block raises where it is asked for.

      def datetime_precision_supported? = true
      def extract_supported? = true
      def quantifiers_supported? = true
      def full_outer_join_supported? = true

      # The FILTER clause, which restricts an aggregate to the rows a condition
      # holds for.  A family without it gets the CASE that means the same,
      # built by the aggregate node.
      def filter_supported? = true

      # A lateral join is allowed to stand unless the family refuses it here.
      def check_lateral(_model); end

      # --- Expressions built differently per family.

      # BIT_COUNT of a number.  The standard has no equivalent; the families
      # that do override.
      def bit_count(_expr, model)
        raise NotImplementedError,
          "bit_count has no equivalent on #{model.connection_db_config.adapter}"
      end

      # The row an upsert could not insert.  PostgreSQL and SQLite name it;
      # MySQL spells the same thing VALUES(column) and overrides.
      def excluded(column, _model)
        AST::Column.new(:excluded, column)
      end

      # XOR, which no two families spell alike.  The standard is the two
      # operations it is made of, naming each operand twice, as SQLite needs;
      # PostgreSQL and the MySQL family have an operator and override.
      def bitwise_xor(left, right)
        Arel::Nodes::Subtraction.new(
          Arel::Nodes::Grouping.new(Arel::Nodes::BitwiseOr.new(left, right)),
          Arel::Nodes::Grouping.new(Arel::Nodes::BitwiseAnd.new(left, right)))
      end

      # --- Reading JSON.  The defaults are what an unclassified adapter gets,
      #     which is SQLite's operators for a path and its functions elsewhere.

      # dig / dig_text.  The standard is SQLite's -> and ->>, whose ->> keeps
      # the value's type, so dig_text casts to text for a portable comparison.
      def json_path(document, dollar_path, _steps, json_value, _model)
        extracted = Arel::Nodes::InfixOperation.new(
          json_value ? :"->" : :"->>", document, Arel::Nodes.build_quoted(dollar_path))
        return extracted if json_value
        Arel::Nodes::NamedFunction.new(
          "CAST", [Arel::Nodes::As.new(extracted, Arel::Nodes::SqlLiteral.new("text"))])
      end

      # A Ruby value on the JSON side of a comparison belongs to a JSON type;
      # a family without one refuses it.
      def json_literal(_json, model)
        raise NotImplementedError,
          "a JSON comparison has no equivalent on " \
          "#{model.connection_db_config.adapter}; dig_text gives the value"
      end

      def json_contains(_document, _json, model)
        raise NotImplementedError,
          "contains? has no equivalent on #{model.connection_db_config.adapter}"
      end

      def json_has_key(document, _name, path, _model)
        Arel::Nodes::NamedFunction.new("json_type", [document, path]).not_eq(nil)
      end

      def json_keys(document, _model)
        Arel::Nodes::NamedFunction.new("JSON_KEYS", [document])
      end

      # --- Writing JSON.  A Ruby document or boolean has to be told apart from
      #     a bare scalar, and embedded as the JSON it spells.

      def json_document_value?(value)
        value.is_a?(::Hash) || value.is_a?(::Array) || value == true || value == false
      end

      # A Ruby document or boolean written where one of the JSON functions
      # wants JSON.  The standard marks the literal with JSON_EXTRACT($);
      # SQLite has json() and Oracle FORMAT JSON, and both override.
      def json_argument(value, _model)
        json = Arel::Nodes.build_quoted(JSON.generate(value))
        Arel::Nodes::NamedFunction.new("JSON_EXTRACT", [json, Arel::Nodes.build_quoted("$")])
      end

      # bury: setting a value at a path.  The standard is JSON_SET; PostgreSQL
      # has jsonb_set and Oracle JSON_TRANSFORM, and both override.
      def json_set(document, _steps, dollar_path, value, expression, model)
        Arel::Nodes::NamedFunction.new(
          "JSON_SET",
          [document, Arel::Nodes.build_quoted(dollar_path),
           json_set_value(value, expression, model)])
      end

      # except: removing keys.  The standard removes a path apiece with
      # JSON_REMOVE; PostgreSQL subtracts an array of keys and Oracle removes
      # through JSON_TRANSFORM, and both override.
      def json_remove(document, dollar_paths, _steps, _model)
        Arel::Nodes::NamedFunction.new(
          "JSON_REMOVE",
          [document, *dollar_paths.map { |path| Arel::Nodes.build_quoted(path) }])
      end

      # json_array / json_object built in the row.  The standard says JSON_ARRAY
      # and JSON_OBJECT with the values (and keys alternating); PostgreSQL has
      # the jsonb_build_* pair and Oracle a keyword syntax, and both override.
      def json_build(kind, keys, args, _model)
        Arel::Nodes::NamedFunction.new(
          kind == :array ? "JSON_ARRAY" : "JSON_OBJECT", json_build_body(kind, keys, args))
      end

      # A document or boolean built into json_array/json_object.  The standard
      # marks it JSON as bury does; PostgreSQL casts to jsonb and overrides.
      def json_build_argument(value, model)
        json_argument(value, model)
      end

      # json_arrayagg / json_objectagg gather rows into a document.  The
      # standard names are JSON_ARRAYAGG and JSON_OBJECTAGG; SQLite and
      # PostgreSQL have their own and override.
      def json_aggregate_name(kind)
        kind == :arrayagg ? "JSON_ARRAYAGG" : "JSON_OBJECTAGG"
      end

      # These two keep a NULL as JSON null rather than passing over it, so the
      # CASE that stands in for FILTER would leave one in the document; a
      # family without FILTER for them refuses it.
      def json_aggregate_filter_supported? = true

      # A family that cannot take these two as window functions refuses one.
      def check_json_aggregate_window(_source, _model); end

      # A JSON value in an IN list or a range is compared per element on the
      # MySQL family, which overrides; the standard leaves it to the IN.
      def json_list_by_element? = false

      protected
        # The value beside a path in JSON_SET: an expression as it is, a
        # document or boolean as JSON, a bare scalar quoted.
        def json_set_value(value, expression, model)
          return expression if expression
          return Arel::Nodes.build_quoted(value) unless json_document_value?(value)
          json_argument(value, model)
        end

        # The arguments to JSON_ARRAY/JSON_OBJECT: an array's values as they
        # are, an object's keys alternating with them.
        def json_build_body(kind, keys, args)
          return args if kind == :array
          keys.zip(args).flat_map { |key, arg| [Arel::Nodes.build_quoted(key), arg] }
        end

        # The connection's own visitor and quoting, for the families that write
        # a call out because its grammar no Arel node carries.
        def compile(node, model)
          model.with_connection { |connection| connection.visitor.compile(node) }
        end

        def quote(value, model)
          model.with_connection { |connection| connection.quote(value) }
        end
    end
  end
end
