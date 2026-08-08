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

        def =~(pattern)
          Match.new(self, pattern)
        end

        def !~(pattern)
          Match.new(self, pattern, negated: true)
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

        def member?(element)
          Member.new(self, element)
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
          # Arel matches case-insensitively unless told otherwise, which turns
          # into ILIKE on PostgreSQL. like? means SQL LIKE on every adapter.
          to_arel_operand(operand, table).matches(pattern, escape, true)
        end
      end

      # Containment in a PostgreSQL array column.  The two flavors of "does it
      # contain this?" split by name the way Ruby's own classes do: include? is
      # String's substring match (LIKE), member? is Enumerable's element test,
      # which String does not have.  The elements are rendered as an array
      # literal, which PostgreSQL coerces to the column's element type, so any
      # expression works as the operand and no schema lookup is needed.
      class Member < Predicate
        attr_reader :operand, :elements

        def initialize(operand, element)
          @operand = operand
          @elements = element.is_a?(::Array) ? element : [element]
        end

        def to_arel(table)
          arel_operand = to_arel_operand(operand, table)
          arel_operand.contains(Arel::Nodes.build_quoted(array_literal))
        end

        private

        # PostgreSQL array input syntax: elements joined by commas inside
        # braces, and an element is double-quoted whenever it is empty, spells
        # NULL, or contains a character the parser treats specially.
        def array_literal
          encoded = elements.map do |value|
            s = value.to_s
            if s.empty? || s.casecmp?("null") || s.match?(/[\s{},"\\]/)
              "\"#{s.gsub(/["\\]/) {|c| "\\#{c}" }}\""
            else
              s
            end
          end
          "{#{encoded.join(',')}}"
        end
      end

      # Regular expression match: REGEXP on MySQL, ~ on PostgreSQL.  SQLite has
      # no regexp operator built in, so Arel raises NotImplementedError there.
      class Match < Predicate
        attr_reader :operand, :pattern, :negated

        def initialize(operand, pattern, negated: false)
          @operand = operand
          @pattern = pattern.is_a?(Regexp) ? regexp_source(pattern) : pattern
          @negated = negated
        end

        def to_arel(table)
          arel_operand = to_arel_operand(operand, table)
          if negated
            arel_operand.does_not_match_regexp(pattern)
          else
            arel_operand.matches_regexp(pattern)
          end
        end

        private

        # A Regexp literal reads naturally with =~, but only its source crosses
        # over; the database has its own dialect and no notion of Ruby's flags.
        # Dropping a flag would silently change what the query matches, so
        # anything beyond a plain literal is refused rather than ignored.
        def regexp_source(regexp)
          unless regexp.options.zero?
            raise ArgumentError,
              "#{regexp.inspect} has options that SQL cannot express; " \
              "pass the pattern as a string instead"
          end
          regexp.source
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
