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

        %i[== != =~ !~ > >= < <=].each do |op|
          define_method(op) {|val| Comparison.new(self, op, val) }
        end

        def null?
          Comparison.new(self, :==, nil)
        end

        %i[count sum average maximum minimum].each do |func|
          define_method(func) { Aggregate.new(self, func) }
        end
      end

      class Aggregate < Node
        attr_reader :operand, :function

        def initialize(operand, function)
          @operand = operand
          @function = function
        end

        def to_arel(table)
          arel_operand = case operand
                         when Node then operand.to_arel(table)
                         else table[operand]
                         end
          arel_operand.public_send(function)
        end

        %i[== != =~ !~ > >= < <=].each do |op|
          define_method(op) {|val| Comparison.new(self, op, val) }
        end
      end

      class Function < Node
        attr_reader :name, :args

        def initialize(name, args)
          @name = name
          @args = args
        end

        def to_arel(table)
          arel_args = args.map do |arg|
            case arg
            when Node then arg.to_arel(table)
            when Symbol then table[arg]
            else Arel::Nodes.build_quoted(arg)
            end
          end
          Arel::Nodes::NamedFunction.new(name, arel_args)
        end

        %i[== != =~ !~ > >= < <=].each do |op|
          define_method(op) {|val| Comparison.new(self, op, val) }
        end
      end

      class Comparison < Predicate
        OPERATOR_MAP = {
          :== => :eq, :!= => :not_eq, :=~ => :matches, :!~ => :does_not_match,
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
          when operator == :!= && Range === value
            arel_column.not_between(value)
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
