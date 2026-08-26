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
      end
    end
  end
end
