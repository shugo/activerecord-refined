module ActiveRecord
  module Refinements
    module AST
      class Node
        def to_arel(table)
          raise ScriptError, "subclass must override this method"
        end
      end

      class Predicate < Node
        def &(other)
          And.new(self, other)
        end

        def |(other)
          Or.new(self, other)
        end

        def !
          Not.new(self)
        end
      end

      class Column < Node
        attr_reader :table_name, :column_name

        def initialize(table_name, column_name)
          @table_name = table_name
          @column_name = column_name
        end

        def to_arel(_table)
          Arel::Table.new(table_name)[column_name]
        end

        %i[== != =~ > >= < <=].each do |op|
          define_method(op) {|val| Comparison.new(self, op, val) }
        end
      end

      class Comparison < Predicate
        OPERATOR_MAP = {
          :== => :eq, :!= => :not_eq, :=~ => :matches,
          :> => :gt, :>= => :gteq, :< => :lt, :<= => :lteq
        }.freeze

        attr_reader :column, :operator, :value

        def initialize(column, operator, value)
          @column = column
          @operator = operator
          @value = value
        end

        def to_arel(table)
          arel_column = case column
                        when Node then column.to_arel(table)
                        else table[column]
                        end
          arel_value = case value
                       when Node then value.to_arel(table)
                       else value
                       end
          case
          when operator == :== && Range === value
            arel_column.between(value)
          when operator == :== && Array === value
            arel_column.in(value)
          when operator == :!= && Array === value
            arel_column.not_in(value)
          else
            arel_column.public_send(OPERATOR_MAP.fetch(operator), arel_value)
          end
        end
      end

      class And < Predicate
        attr_reader :left, :right

        def initialize(left, right)
          @left = left
          @right = right
        end

        def to_arel(table)
          left.to_arel(table).and(right.to_arel(table))
        end
      end

      class Or < Predicate
        attr_reader :left, :right

        def initialize(left, right)
          @left = left
          @right = right
        end

        def to_arel(table)
          left.to_arel(table).or(right.to_arel(table))
        end
      end

      class Not < Predicate
        attr_reader :operand

        def initialize(operand)
          @operand = operand
        end

        def to_arel(table)
          Arel::Nodes::Not.new(operand.to_arel(table))
        end
      end
    end
  end
end
