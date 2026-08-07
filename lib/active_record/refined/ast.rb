module ActiveRecord
  module Refined
    module AST
      # Predicate builders shared by symbols, qualified columns and
      # expressions. Imported into the Symbol refinement with
      # Refinement#import_methods, so every method must be defined with def.
      module Predications
        def ==(other)
          Comparison.new(self, :==, other)
        end

        def !=(other)
          Comparison.new(self, :!=, other)
        end

        def >(other)
          Comparison.new(self, :>, other)
        end

        def >=(other)
          Comparison.new(self, :>=, other)
        end

        def <(other)
          Comparison.new(self, :<, other)
        end

        def <=(other)
          Comparison.new(self, :<=, other)
        end

        def null?
          Comparison.new(self, :==, nil)
        end

        def in?(values)
          In.new(self, values)
        end

        def between?(min, max)
          In.new(self, min..max)
        end

        def like?(pattern)
          Like.new(self, pattern)
        end

        def start_with?(prefix)
          Like.new(self, "#{Like.escape(prefix)}%", Like::ESCAPE)
        end

        def end_with?(suffix)
          Like.new(self, "%#{Like.escape(suffix)}", Like::ESCAPE)
        end

        def include?(substring)
          Like.new(self, "%#{Like.escape(substring)}%", Like::ESCAPE)
        end
      end

      class Node
        def to_arel(table)
          raise ScriptError, "subclass must override this method"
        end

        def as(alias_name)
          As.new(self, alias_name)
        end

        def asc
          Ordering.new(self, :asc)
        end

        def desc
          Ordering.new(self, :desc)
        end

        private

        # Resolves an operand denoting a column or an expression.
        def to_arel_operand(operand, table)
          case operand
          when Node then operand.to_arel(table)
          when :* then Arel.star
          when Symbol then table[operand]
          else operand
          end
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
        include Predications

        attr_reader :table_name, :column_name

        def initialize(table_name, column_name)
          @table_name = table_name
          @column_name = column_name
        end

        def to_arel(_table)
          Arel::Table.new(table_name)[column_name]
        end

        %i[count sum average maximum minimum].each do |func|
          define_method(func) { Aggregate.new(self, func) }
        end
      end

      class Aggregate < Node
        include Predications

        attr_reader :operand, :function

        def initialize(operand, function)
          @operand = operand
          @function = function
        end

        def to_arel(table)
          to_arel_operand(operand, table).public_send(function)
        end
      end

      class As < Node
        attr_reader :operand, :alias_name

        def initialize(operand, alias_name)
          @operand = operand
          @alias_name = alias_name
        end

        def to_arel(table)
          to_arel_operand(operand, table).as(alias_name.to_s)
        end
      end

      class Ordering < Node
        attr_reader :operand, :direction

        def initialize(operand, direction)
          @operand = operand
          @direction = direction
        end

        def to_arel(table)
          to_arel_operand(operand, table).public_send(direction)
        end
      end

      class Function < Node
        include Predications

        attr_reader :name, :args

        def initialize(name, args)
          @name = name
          @args = args
        end

        def to_arel(table)
          arel_args = args.map do |arg|
            case arg
            when Node, Symbol then to_arel_operand(arg, table)
            else Arel::Nodes.build_quoted(arg)
            end
          end
          Arel::Nodes::NamedFunction.new(name, arel_args)
        end
      end

      # A plain SQL comparison. The value is passed through as it is, so a Range
      # or an Array compares against a PostgreSQL range or array column, the way
      # ActiveRecord's own force_equality? types do.
      class Comparison < Predicate
        OPERATOR_MAP = {
          :== => :eq, :!= => :not_eq,
          :> => :gt, :>= => :gteq, :< => :lt, :<= => :lteq
        }.freeze

        attr_reader :column, :operator, :value

        def initialize(column, operator, value)
          @column = column
          @operator = operator
          @value = value
        end

        def to_arel(table)
          arel_column = to_arel_operand(column, table)
          arel_value = value.is_a?(Node) ? value.to_arel(table) : value
          arel_column.public_send(OPERATOR_MAP.fetch(operator), arel_value)
        end
      end

      # IN for a list of values, BETWEEN for a range.
      class In < Predicate
        attr_reader :operand, :values

        def initialize(operand, values)
          @operand = operand
          @values = values
        end

        def to_arel(table)
          arel_operand = to_arel_operand(operand, table)
          case values
          when Range then arel_operand.between(values)
          else arel_operand.in(values)
          end
        end
      end

      class Like < Predicate
        ESCAPE = "\\".freeze

        # Escapes % and _ so that they match literally. The pattern built from
        # the result must be used with ESCAPE, since SQLite has no default
        # escape character.
        def self.escape(string)
          ActiveRecord::Base.sanitize_sql_like(string, ESCAPE)
        end

        attr_reader :operand, :pattern, :escape

        def initialize(operand, pattern, escape = nil)
          @operand = operand
          @pattern = pattern
          @escape = escape
        end

        def to_arel(table)
          to_arel_operand(operand, table).matches(pattern, escape)
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
