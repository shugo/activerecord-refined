# frozen_string_literal: true

module ActiveRecord
  module Refined
    class Dialect
      # What MySQL and MariaDB share, which is most of it; the two part company
      # only in the Mysql and Mariadb subclasses.
      class MysqlCompat < Dialect
        FUNCTIONS = { trunc: "TRUNCATE", date_trunc: nil, format: nil }.freeze

        def full_outer_join_supported? = false
        def filter_supported? = false

        def bit_count(expr, _model)
          AST::Function.new("BIT_COUNT", [expr])
        end

        # The excluded row is VALUES(column), which takes the column bare.
        def excluded(column, model)
          quoted = model.with_connection { |connection| connection.quote_column_name(column) }
          AST::Function.new("VALUES", [Arel::Nodes::SqlLiteral.new(quoted)])
        end

        def bitwise_xor(left, right)
          Arel::Nodes::BitwiseXor.new(left, right)
        end

        def json_path(document, dollar_path, _steps, json_value, _model)
          extracted = Arel::Nodes::NamedFunction.new(
            "JSON_EXTRACT", [document, Arel::Nodes.build_quoted(dollar_path)])
          return extracted if json_value
          Arel::Nodes::NamedFunction.new("JSON_UNQUOTE", [extracted])
        end

        def json_contains(document, json, _model)
          Arel::Nodes::NamedFunction.new("JSON_CONTAINS", [document, json])
        end

        def json_has_key(document, _name, path, _model)
          Arel::Nodes::NamedFunction.new(
            "JSON_CONTAINS_PATH", [document, Arel::Nodes.build_quoted("one"), path])
        end

        def json_aggregate_filter_supported? = false

        # GROUP_CONCAT, its separator a keyword after the operand and after
        # the ORDER BY when there is one.
        def string_agg(operand, separator, orders, _string, model)
          order = orders.empty? ? "" : " ORDER BY #{compile_list(orders, model)}"
          Arel.sql("GROUP_CONCAT(#{compile(operand, model)}#{order} " \
                   "SEPARATOR #{quote(separator, model)})")
        end

        def check_string_aggregate_window(model)
          raise NotImplementedError,
            "string_agg over a window has no equivalent on #{model.connection_db_config.adapter}"
        end

        def json_list_by_element? = true

        def grouping_supported?(kind) = kind == :rollup

        def grouping_by_with_rollup? = true
      end
    end
  end
end
