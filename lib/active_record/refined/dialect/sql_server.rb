# frozen_string_literal: true

module ActiveRecord
  module Refined
    class Dialect
      # Microsoft SQL Server, reached through the sqlserver adapter over
      # tiny_tds.  Loaded only when a query is built for it.
      class SqlServer < Dialect
        # LEN is its length; it has no printf FORMAT, no per-row random it
        # would spell RAND, no date_trunc, and none of the bit aggregates.
        FUNCTIONS = {
          char_length: "LEN",
          format: nil, rand: nil, date_trunc: nil,
          bit_and: nil, bit_or: nil, bit_xor: nil,
        }.freeze

        # No FILTER clause, so the aggregate node builds the CASE instead.
        def filter_supported? = false

        # No EXTRACT (it has DATEPART), and its datetime value functions take
        # no precision.
        def extract_supported? = false
        def datetime_precision_supported? = false

        # No boolean type: the column is a bit, so true? is = 1 and false? = 0.
        # The negations keep a NULL, which = would drop, by naming it.
        def truth_value(operand, value, negated, _model)
          equals = Arel::Nodes::Equality.new(operand, value ? 1 : 0)
          return equals unless negated
          Arel::Nodes::Grouping.new(
            Arel::Nodes::Or.new([
              Arel::Nodes::Equality.new(operand, value ? 0 : 1),
              Arel::Nodes::Equality.new(operand, nil),
            ]))
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
