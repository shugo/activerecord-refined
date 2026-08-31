# frozen_string_literal: true

module ActiveRecord
  module Refined
    class Dialect
      # SQLite: the fewest of the extras, and a JSON path through its own
      # operators.
      class Sqlite < Dialect
        # @private
        FUNCTIONS = {
          char_length: "LENGTH", greatest: "MAX", least: "MIN",
          now: nil, date_trunc: nil, rand: "RANDOM",
          bit_and: nil, bit_or: nil, bit_xor: nil,
          localtime: nil, localtimestamp: nil,
        }.freeze

        def datetime_precision_supported? = false
        def extract_supported? = false
        def quantifiers_supported? = false

        def check_lateral(model)
          raise NotImplementedError,
            "a lateral join has no equivalent on #{model.connection_db_config.adapter}"
        end

        # A date is moved by a modifier to date() or datetime(), '+3 day';
        # the unit's own name reads there, singular.  datetime() answers with a
        # time of day whatever it is given, so a date column, as the node
        # tells one, goes through date() and stays a date.
        def add_interval(date, amount, unit, subtract, date_only)
          modifier = format("%+d %s", subtract ? -amount : amount, unit)
          Arel::Nodes::NamedFunction.new(
            date_only ? "date" : "datetime", [date, Arel::Nodes.build_quoted(modifier)])
        end

        def json_keys(document, model)
          sql = compile(document, model)
          Arel.sql("CASE WHEN json_type(#{sql}) = 'object' " \
                   "THEN (SELECT json_group_array(key) FROM json_each(#{sql})) END")
        end

        def json_argument(value, _model)
          Arel::Nodes::NamedFunction.new(
            "json", [Arel::Nodes.build_quoted(JSON.generate(value))])
        end

        def json_aggregate_name(kind)
          kind == :arrayagg ? "json_group_array" : "json_group_object"
        end

        # group_concat, with the ORDER BY inside the call from 3.44 on.
        def string_agg(operand, separator, orders, _string, model)
          string_agg_call("group_concat", operand, separator, orders, model)
        end
      end
    end
  end
end
