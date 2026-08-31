# frozen_string_literal: true

module ActiveRecord
  module Refined
    class Dialect
      # Oracle, reached through oracle_enhanced.  Loaded only when a query is
      # built for it.
      class Oracle < Dialect
        # @private
        FUNCTIONS = {
          char_length: "LENGTH",
          degrees: nil, radians: nil, pi: nil, log2: nil, log10: nil,
          now: nil, date_trunc: nil, rand: nil, format: nil,
          bit_and: nil, bit_or: nil, bit_xor: nil,
        }.freeze

        # An INTERVAL literal would do, but its leading field is two digits
        # wide unless told otherwise, so INTERVAL '100' DAY is an error.  The
        # functions that make an interval of a number take any size, one for
        # the year-month intervals and one for the day-second.
        def add_interval(date, amount, unit, subtract, _date_only)
          interval = Arel::Nodes::NamedFunction.new(
            unit == :year || unit == :month ? "NUMTOYMINTERVAL" : "NUMTODSINTERVAL",
            [Arel::Nodes.build_quoted(amount), Arel::Nodes.build_quoted(unit.to_s.upcase)])
          Arel::Nodes::Grouping.new(
            Arel::Nodes::InfixOperation.new(subtract ? :- : :+, date, interval))
        end

        # Oracle keeps scalars and structures in different functions: JSON_VALUE
        # reads a scalar out as text, JSON_QUERY a fragment as JSON.  dig keeps
        # JSON, so it takes JSON_QUERY with 23ai's ALLOW SCALARS, which returns
        # a scalar leaf as itself rather than wrapping or refusing it.
        def json_path(document, dollar_path, _steps, json_value, model)
          unless json_value
            return Arel::Nodes::NamedFunction.new(
              "JSON_VALUE", [document, Arel::Nodes.build_quoted(dollar_path)])
          end
          Arel.sql(
            "JSON_QUERY(#{compile(document, model)}, " \
            "#{quote(dollar_path, model)} RETURNING VARCHAR2(4000) ALLOW SCALARS " \
            "NULL ON EMPTY)")
        end

        def json_has_key(document, _name, path, _model)
          Arel::Nodes::NamedFunction.new("JSON_EXISTS", [document, path])
        end

        # No JSON_KEYS, and the keys reach only through a JSON_TABLE unnest not
        # written yet.
        def json_keys(_document, model)
          raise NotImplementedError,
            "keys has no equivalent on #{model.connection_db_config.adapter}"
        end

        def json_argument(value, model)
          Arel.sql("#{quote(JSON.generate(value), model)} FORMAT JSON")
        end

        # JSON_TRANSFORM is Oracle's one editing function; its SET and the value
        # beside it are grammar, so the call is written out, RETURNING text that
        # ruby-oci8 can fetch.
        def json_set(document, _steps, dollar_path, value, expression, model)
          model.with_connection do |connection|
            set =
              if expression
                connection.visitor.compile(expression)
              elsif json_document_value?(value)
                "#{connection.quote(JSON.generate(value))} FORMAT JSON"
              else
                connection.quote(value)
              end
            Arel.sql(
              "JSON_TRANSFORM(#{connection.visitor.compile(document)}, " \
              "SET #{connection.quote(dollar_path)} = #{set} RETURNING VARCHAR2(4000))")
          end
        end

        def json_remove(document, dollar_paths, _steps, model)
          model.with_connection do |connection|
            removes = dollar_paths.map { |path| "REMOVE #{connection.quote(path)}" }
            Arel.sql(
              "JSON_TRANSFORM(#{connection.visitor.compile(document)}, " \
              "#{removes.join(', ')} RETURNING VARCHAR2(4000))")
          end
        end

        # Oracle pairs a key with its value by the VALUE keyword rather than by
        # position, keeps a NULL only when told NULL ON NULL, and returns the
        # native JSON type unless a RETURNING asks for text ruby-oci8 can fetch.
        def json_build(kind, keys, args, model)
          model.with_connection do |connection|
            compiled = args.map { |arg| connection.visitor.compile(arg) }
            body =
              if kind == :array
                compiled.join(", ")
              else
                keys.zip(compiled).map { |key, arg| "#{connection.quote(key)} VALUE #{arg}" }.join(", ")
              end
            Arel.sql("JSON_#{kind.to_s.upcase}(#{body} NULL ON NULL RETURNING VARCHAR2(4000))")
          end
        end

        def check_json_aggregate_window(source, model)
          raise NotImplementedError,
            "#{source} over a window has no equivalent on " \
            "#{model.connection_db_config.adapter}"
        end
      end
    end
  end
end
