# frozen_string_literal: true

module ActiveRecord
  module Refined
    class Dialect
      # Microsoft SQL Server, reached through the sqlserver adapter over
      # tiny_tds.  Loaded only when a query is built for it.
      class SqlServer < Dialect
        # LEN is its length; it has no printf FORMAT, no per-row random it
        # would spell RAND, no date_trunc, and none of the bit aggregates.
        # Of the datetime value functions it has CURRENT_TIMESTAMP alone:
        # the other four are reserved words there that stand for nothing.
        FUNCTIONS = {
          char_length: "LEN",
          format: nil, rand: nil, date_trunc: nil,
          bit_and: nil, bit_or: nil, bit_xor: nil,
          current_date: nil, current_time: nil, localtime: nil, localtimestamp: nil,
        }.freeze

        # No FILTER clause, so the aggregate node builds the CASE instead.
        def filter_supported? = false

        # No EXTRACT (it has DATEPART), and its datetime value functions take
        # no precision.
        def extract_supported? = false
        def datetime_precision_supported? = false

        # No boolean type: the column is a bit.  ISNULL reads a NULL as the
        # value the test is not looking for -- 0 for true?, 1 for false? --
        # so the plain form drops it and, being never NULL itself, the
        # negation is exactly NOT of the plain form, matching what ! builds.
        def truth_value(operand, value, negated, _model)
          equals = Arel::Nodes::Equality.new(
            Arel::Nodes::NamedFunction.new("ISNULL", [operand, value ? 0 : 1]),
            value ? 1 : 0)
          negated ? Arel::Nodes::Not.new(equals) : equals
        end

        # DATEADD(day, 3, x), the unit a bare keyword; a subtraction is a
        # negative amount, there being no DATESUB.
        def add_interval(date, amount, unit, subtract, _date_only)
          Arel::Nodes::NamedFunction.new(
            "DATEADD",
            [Arel::Nodes::SqlLiteral.new(unit.to_s),
             Arel::Nodes.build_quoted(subtract ? -amount : amount), date])
        end

        # dig_text reads a scalar out with JSON_VALUE; dig keeps JSON with
        # JSON_QUERY, which returns a fragment and NULL for a scalar leaf.
        def json_path(document, dollar_path, _steps, json_value, _model)
          Arel::Nodes::NamedFunction.new(
            json_value ? "JSON_QUERY" : "JSON_VALUE",
            [document, Arel::Nodes.build_quoted(dollar_path)])
        end

        # JSON_PATH_EXISTS returns a bit, which the condition compares to 1.
        def json_has_key(document, _name, path, _model)
          Arel::Nodes::Equality.new(
            Arel::Nodes::NamedFunction.new("JSON_PATH_EXISTS", [document, path]),
            Arel::Nodes.build_quoted(1))
        end

        # A document, a boolean or a bare scalar written where JSON is wanted
        # rides in through JSON_QUERY as the JSON it spells.
        def json_argument(value, _model)
          Arel::Nodes::NamedFunction.new(
            "JSON_QUERY", [Arel::Nodes.build_quoted(JSON.generate(value))])
        end

        # bury: JSON_MODIFY sets a value at a path.
        def json_set(document, _steps, dollar_path, value, expression, model)
          Arel::Nodes::NamedFunction.new(
            "JSON_MODIFY",
            [document, Arel::Nodes.build_quoted(dollar_path),
             json_modify_value(value, expression, model)])
        end

        # except: JSON_MODIFY deletes a key when it sets it to a literal NULL,
        # one nested call per key.
        def json_remove(document, dollar_paths, _steps, _model)
          dollar_paths.reduce(document) do |doc, path|
            Arel::Nodes::NamedFunction.new(
              "JSON_MODIFY",
              [doc, Arel::Nodes.build_quoted(path), Arel::Nodes::SqlLiteral.new("NULL")])
          end
        end

        private
          # A document or array goes in through JSON_QUERY, which wants an
          # object or an array and refuses a scalar; a bare scalar is quoted.
          # A boolean, a null or a dug scalar is bury's business the tests skip.
          def json_modify_value(value, expression, model)
            return expression if expression
            return json_argument(value, model) if value.is_a?(::Hash) || value.is_a?(::Array)
            Arel::Nodes.build_quoted(value)
          end
      end
    end
  end
end
