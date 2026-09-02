# frozen_string_literal: true

require "active_record/refined/ast/node"
require "active_record/refined/ast/windows"

module ActiveRecord
  module Refined
    module AST
      # An aggregate -- `COUNT`, `SUM`, `AVG`, `MIN`, `MAX` -- over a group,
      # or, given {Windowing#over}, a window.
      class Aggregate < Node
        include Predications
        include Arithmetics
        include Windowing

        # The aggregates DISTINCT changes: over each value once, count counts
        # fewer and sum and avg reckon less.  min and max give the same
        # either way, so a DISTINCT there is refused as saying nothing.
        # @private
        DISTINCT_FUNCTIONS = %i[count sum average].freeze

        # @private
        attr_reader :operand, :function, :distinct, :condition

        def initialize(operand, function, distinct: false, condition: nil)
          if distinct && !DISTINCT_FUNCTIONS.include?(function)
            raise ArgumentError, "#{function} does not take distinct; it would give the same"
          end
          if distinct && operand == :*
            raise ArgumentError, "count(:*) does not take distinct; name a column"
          end
          @operand = operand
          @function = function
          @distinct = distinct
          @condition = condition
        end

        # `FILTER (WHERE condition)`: the aggregate taken over the rows the
        # condition holds for, as a value or a block.  Where there is no
        # FILTER clause -- MySQL, SQL Server -- the CASE that means the same.
        # @return [AST::Aggregate]
        # @example
        #   Author.select { [count(:*).as(:all), count(:*).filter { :age < 50 }.as(:young)] }
        def filter(condition = nil, &block)
          Aggregate.new(operand, function, distinct: distinct,
                        condition: Case.argument(:filter, condition, block))
        end

        # @private
        def to_arel(table, model)
          return aggregate(operand, table, model) unless condition

          # A family without a FILTER clause gets the CASE that means the same.
          # An aggregate passes over a NULL, so the case that yields nothing for
          # the rows the condition misses is the same aggregate over the same
          # rows -- count(*) has no operand to keep, and counts a 1 instead.
          unless Dialect.for(model).filter_supported?
            kept = Case.new.when(condition).then(operand == :* ? 1 : operand)
            return aggregate(kept, table, model)
          end

          aggregate(operand, table, model).filter(condition.to_arel(table, model))
        end

        private
          def aggregate(over, table, model)
            arel_operand = to_arel_operand(over, table, model)
            return arel_operand.count(distinct) if function == :count
            call = arel_operand.public_send(function)
            call.distinct = distinct
            call
          end
      end

      # The strings of a group joined into one, a separator between:
      # `string_agg(:title, ", ")`, with `.order` for the order they are
      # joined in.  Every family has it under a name of its own with the
      # ORDER BY in a place of its own, and Arel has no node for an ORDER BY
      # inside a call, so the dialect writes the call.  A NULL is passed
      # over as by any aggregate, so the CASE that stands in for FILTER
      # means the same here and is not refused as the JSON aggregates' is.
      class StringAggregate < Node
        include Predications
        include Windowing

        # @private
        attr_reader :operand, :separator, :orders, :condition

        def initialize(operand, separator, orders: [], condition: nil)
          unless separator.is_a?(::String)
            raise ArgumentError, "#{separator.inspect} is not a String separator"
          end
          @operand = operand
          @separator = separator
          @orders = orders
          @condition = condition
        end

        # The order the strings are joined in: columns, or orderings such as
        # `:title.desc`.
        # @return [AST::StringAggregate]
        def order(*exprs)
          raise ArgumentError, "order needs an expression" if exprs.empty?
          StringAggregate.new(operand, separator, orders: orders + exprs, condition: condition)
        end

        # `FILTER (WHERE condition)`, as {Aggregate#filter}.
        # @return [AST::StringAggregate]
        def filter(condition = nil, &block)
          StringAggregate.new(operand, separator, orders: orders,
                              condition: Case.argument(:filter, condition, block))
        end

        # @private
        def check_window(model)
          Dialect.for(model).check_string_aggregate_window(model)
        end

        # @private
        def to_arel(table, model)
          dialect = Dialect.for(model)
          kept = condition && !dialect.filter_supported? ?
            Case.new.when(condition).then(operand) : operand
          call = dialect.string_agg(
            to_arel_argument(kept, table, model), separator,
            orders.map { |expr| to_arel_operand(expr, table, model) },
            string_operand?(model), model)
          return call unless condition && dialect.filter_supported?
          Arel::Nodes::Filter.new(call, condition.to_arel(table, model))
        end

        private
          # Whether the operand is a column the model declares a string.
          # PostgreSQL asks, its STRING_AGG taking text and nothing else; the
          # others convert for themselves.
          def string_operand?(model)
            operand.is_a?(::Symbol) &&
              %i[string text].include?(model.type_for_attribute(operand).type)
          end
      end

      # A function call, `UPPER(name)`: what the scalar functions of
      # {BlockContext} build, and {BlockContext#fn} for a function the list
      # does not name.
      class Function < Node
        include Predications
        include Arithmetics
        include Windowing

        # @private
        attr_reader :name, :args

        def initialize(name, args)
          @name = name
          @args = args
        end

        # @private
        def to_arel(table, model)
          arel_args = args.map { |arg| to_arel_argument(arg, table, model) }
          Arel::Nodes::NamedFunction.new(name, arel_args)
        end
      end

      # ROW_NUMBER and its kind: functions that say nothing without a window.
      # On its own this refuses rather than reaching the database as an error
      # there; over asks it for call_arel instead.
      class WindowFunction < Function
        # @private
        alias_method :call_arel, :to_arel

        # @private
        def to_arel(_table, _model)
          raise ArgumentError, "#{name.downcase} is a window function; it needs over"
        end
      end

      # EXTRACT(field FROM expr).  The field is grammar rather than a value --
      # a keyword the adapter reads bare -- so it has to be a plain name,
      # which Arel upcases on the way out.
      class Extract < Node
        include Predications
        include Arithmetics

        # @private
        attr_reader :field, :operand

        def initialize(field, operand)
          @field = AST.check_name(field, ALIAS_NAME, "extract field")
          @operand = operand
        end

        # @private
        def to_arel(table, model)
          Arel::Nodes::Extract.new(to_arel_argument(operand, table, model), field.to_s)
        end
      end

      # CAST(expr AS type).  The type is grammar too, written into the SQL as
      # given -- it is the adapter's own name for the type, and whether it
      # exists is the database's to say -- so it has to look like one:
      # a plain name, at most parenthesized with lengths.
      class Cast < Node
        include Predications
        include Arithmetics

        # @private
        attr_reader :operand, :sql_type

        def initialize(operand, sql_type)
          @operand = operand
          @sql_type = AST.check_name(sql_type, TYPE_NAME, "SQL type")
        end

        # @private
        def to_arel(table, model)
          Arel::Nodes::NamedFunction.new(
            "CAST",
            [Arel::Nodes::As.new(to_arel_argument(operand, table, model),
                                 Arel::Nodes::SqlLiteral.new(sql_type.to_s))])
        end
      end

      # CURRENT_TIMESTAMP and its relatives, what the SQL grammar calls a
      # datetime value function.  The grammar has them bare, and PostgreSQL
      # and SQLite reject them written as calls, so unlike Function the name
      # is emitted without parentheses.  A precision is the one thing that
      # does go into parentheses, and it is written into the SQL as given, so
      # only an Integer is accepted.
      class DatetimeValueFunction < Node
        include Predications
        include Arithmetics

        # @private
        attr_reader :name, :precision

        def initialize(name, precision = nil)
          unless precision.nil? || precision.is_a?(Integer)
            raise ArgumentError,
              "#{precision.inspect} is not an Integer precision"
          end
          @name = name
          @precision = precision
        end

        # @private
        def to_arel(_table, _model)
          Arel::Nodes::SqlLiteral.new(
            precision ? "#{name}(#{precision})" : name)
        end
      end
    end
  end
end
