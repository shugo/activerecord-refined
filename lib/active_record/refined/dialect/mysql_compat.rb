# frozen_string_literal: true

module ActiveRecord
  module Refined
    class Dialect
      # What MySQL and MariaDB share, which is most of it; the two part company
      # only in the Mysql and Mariadb subclasses.
      class MysqlCompat < Dialect
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

        def json_list_by_element? = true
      end
    end
  end
end
