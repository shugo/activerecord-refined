# frozen_string_literal: true

require "active_record/refined/ast/node"

module ActiveRecord
  module Refined
    module AST
      # CASE, in both of the shapes SQL has for it.  With an operand, each
      # `when` is something to compare it against; without one, each `when` is
      # a condition of its own.
      #
      # Every method returns a new node rather than adding to this one, so a
      # case kept in a variable can be branched from more than once.
      class Case < Node
        include Predications
        include Arithmetics

        # Having no ELSE is not the same as an ELSE of nil, and nil is what an
        # omitted argument looks like, so the absence needs a value of its own.
        NOTHING = Object.new.freeze
        private_constant :NOTHING

        # @private
        attr_reader :operand, :whens, :default

        def initialize(operand = nil, whens = [], default = NOTHING)
          @operand = operand
          @whens = whens
          @default = default
        end

        # The next `WHEN`: a value to compare the operand against, or a condition as a value or a block.
        # @return [AST::Case::When]
        def when(value = nil, &block)
          When.new(self, Case.argument(:when, value, block))
        end

        # `THEN`, which belongs after a `when`; here it says so.
        # @raise [ArgumentError]
        #
        # Kernel#then is on every object, so `then` in the wrong place would be
        # answered by it -- with no block, silently, with an Enumerator.
        def then(*)
          raise ArgumentError, "then follows a when, and there is none to follow here"
        end

        # `ELSE value`, as a value or a block, closing the CASE.  Without one the CASE gives NULL where no `when` matched.
        # @return [AST::Case]
        def else(value = nil, &block)
          Case.new(operand, whens, Case.argument(:else, value, block))
        end

        # @private
        def to_arel(table, model)
          raise ArgumentError, "case needs a when before it means anything" if whens.empty?

          node = operand ? Arel::Nodes::Case.new(to_arel_operand(operand, table, model))
                         : Arel::Nodes::Case.new
          whens.each do |condition, result|
            node.when(to_arel_argument(condition, table, model)).
              then(to_arel_argument(result, table, model))
          end
          node.else(to_arel_argument(default, table, model)) unless default.equal?(NOTHING)
          node
        end

        # A value or a block, and exactly one of them: the block is what makes
        # `when { :age >= 60 }` read like the blocks around it, and the value is
        # what makes `when(10)` possible at all.
        # @private
        def self.argument(name, value, block)
          if block
            raise ArgumentError, "#{name} takes a value or a block, not both" unless value.nil?
            return block.call
          end
          raise ArgumentError, "#{name} needs a value or a block" if value.nil?
          value
        end

        # What a `when` is until its `then` arrives.  A Node so that using it
        # as one says what is missing rather than reaching Active Record as
        # something it cannot read.
        class When < Node
          def initialize(kase, condition)
            @kase = kase
            @condition = condition
          end

          # `THEN value`, as a value or a block, for the `when` before it.
          # @return [AST::Case]
          def then(value = nil, &block)
            Case.new(@kase.operand,
                     @kase.whens + [[@condition, Case.argument(:then, value, block)]],
                     @kase.default)
          end

          # @private
          def to_arel(_table, _model)
            raise ArgumentError, "when needs a matching then"
          end
        end
      end

      # Arithmetic on columns and expressions.  Ruby's precedence puts these
      # above the comparison operators, so :price * :quantity > 100 groups the
      # way it reads.
      #
      # A Duration on the right moves a date: `:due_on + 3.days`.  No two
      # families spell the move alike, so the dialect writes it, a part of the
      # duration at a time.
      class Arithmetic < Node
        include Predications
        include Arithmetics

        # Active Support's parts, as the units the SQL takes.  A week is seven
        # days: SQLite and Oracle have no week.
        # @private
        UNITS = {
          years: :year, months: :month, weeks: :day, days: :day,
          hours: :hour, minutes: :minute, seconds: :second,
        }.freeze

        # @private
        DATE_UNITS = %i[year month day].freeze

        # @private
        attr_reader :left, :operator, :right

        def initialize(left, operator, right)
          @left = left
          @operator = operator
          @right = right
        end

        # @private
        def to_arel(table, model)
          arel_left = to_arel_operand(left, table, model)
          return move_date(arel_left, model) if right.is_a?(::ActiveSupport::Duration)
          # The operator dispatches Arel's Math, which a bare number carries
          # none of; quoted, it is a node with the same methods.
          arel_left = Arel::Nodes.build_quoted(arel_left) if arel_left.is_a?(::Numeric)
          arel_left.public_send(operator, to_arel_operand(right, table, model))
        end

        # SQLite has no date type, and its datetime() gives whatever it is
        # handed a time of day, so a date column moved by a day would come
        # back a midnight and sort past the same day written bare.  Its
        # dialect has date() for what is a date to begin with, and this is
        # what says so: a column the model declares a date, CURRENT_DATE, or
        # one of those already moved by a date's units.  The other families
        # keep the type themselves and never ask.
        # @private
        def self.date_operand?(operand, model)
          case operand
          when ::Symbol then model.type_for_attribute(operand).type == :date
          when DatetimeValueFunction then operand.name == "CURRENT_DATE"
          when Arithmetic
            operand.right.is_a?(::ActiveSupport::Duration) &&
              date_operand?(operand.left, model) &&
              operand.right.parts.keys.all? { |part| DATE_UNITS.include?(UNITS[part]) }
          else false
          end
        end

        private
          # Each amount is written into the SQL as a number, and a fraction
          # of a unit is not one every family takes, so it has to be a whole
          # one.
          def move_date(date, model)
            unless operator == :+ || operator == :-
              raise ArgumentError,
                "a duration is added to a date or subtracted from it, not #{operator}"
            end
            dialect = Dialect.for(model)
            date_only = Arithmetic.date_operand?(left, model)
            right.parts.reduce(date) do |arel, (part, amount)|
              unless amount.is_a?(::Integer)
                raise ArgumentError, "#{amount.inspect} #{part} is not a whole number of them"
              end
              unit = UNITS.fetch(part)
              amount *= 7 if part == :weeks
              dialect.add_interval(arel, amount, unit, operator == :-,
                                   date_only && DATE_UNITS.include?(unit))
            end
          end
      end

      # What the bitwise operations refuse.  Both refusals are there because
      # the same Ruby would otherwise mean different things per adapter: MySQL
      # and SQLite take a boolean for the one bit it is stored as, so
      # `published.bitwise_and(active)` would quietly be the AND it looks
      # like, while PostgreSQL has no such operator and would say so.
      # @private
      module BitwiseOperands
        private
          # Oracle is the family with no bitwise operators at all -- BITAND
          # is a function, with no OR, XOR, shift or NOT beside it -- so the
          # node refuses there before its server has to.
          def check_operators_exist(model)
            return if Dialect.for(model).bitwise_operators_supported?
            raise NotImplementedError,
              "the bitwise operations have no equivalent on " \
              "#{model.connection_db_config.adapter}"
          end

          # A predicate alone is refused.  The escape hatches are not: what
          # sql() or op() holds is as often an expression as a condition, and
          # here it is being read as the former.
          def check_operand(operand)
            return operand unless operand.is_a?(Predicate)
            raise ArgumentError,
              "a condition cannot be an operand of a bitwise operation; " \
              "& and | between conditions are AND and OR"
          end

          # Only the unqualified column can be checked, since that is the one
          # the model is known to have.
          def check_not_boolean(operand, model)
            return unless operand.is_a?(::Symbol)
            return unless model.type_for_attribute(operand).type == :boolean
            raise ArgumentError,
              "#{operand.inspect} is a boolean column, which the bitwise " \
              "operations do not take; #{operand.inspect}.true? is the condition"
          end
      end

      # SQL's bitwise operations.  Each parenthesises itself, which is what
      # keeps the grouping the Ruby asked for: PostgreSQL gives & and | the
      # same precedence and reads a | b & c from the left, where
      # a.bitwise_or(b.bitwise_and(c)) means the other thing.
      class Bitwise < Node
        include Predications
        include Arithmetics
        include BitwiseOperands

        # @private
        NODES = {
          :& => Arel::Nodes::BitwiseAnd,
          :| => Arel::Nodes::BitwiseOr,
          :<< => Arel::Nodes::BitwiseShiftLeft,
          :>> => Arel::Nodes::BitwiseShiftRight,
        }.freeze

        # @private
        attr_reader :left, :operator, :right

        def initialize(left, operator, right)
          @left = left
          @operator = operator
          @right = check_operand(right)
        end

        # @private
        def to_arel(table, model)
          check_operators_exist(model)
          check_not_boolean(left, model)
          check_not_boolean(right, model)
          arel_left = to_arel_operand(left, table, model)
          arel_right = to_arel_argument(right, table, model)
          Arel::Nodes::Grouping.new(
            if operator == :^
              xor(arel_left, arel_right, model)
            else
              NODES.fetch(operator).new(arel_left, arel_right)
            end)
        end

        private
          # Arel has a node for XOR, but it writes ^ on every adapter, and ^ is
          # exponentiation to PostgreSQL -- a wrong answer rather than an error.
          # PostgreSQL's own spelling, #, is where a comment starts on MySQL, so
          # it cannot be the portable one either.  SQLite has no XOR at all;
          # (a | b) - (a & b) is it, at the cost of naming each operand twice.
          def xor(left, right, model)
            Dialect.for(model).bitwise_xor(left, right)
          end
      end

      # ~, which every adapter has.  MySQL answers with the unsigned 64-bit
      # number where the others answer with a negative one; the bits are the
      # same, and only reading the value back tells them apart.
      class BitwiseNot < Node
        include Predications
        include Arithmetics
        include BitwiseOperands

        # @private
        attr_reader :operand

        def initialize(operand)
          @operand = check_operand(operand)
        end

        # @private
        def to_arel(table, model)
          check_operators_exist(model)
          check_not_boolean(operand, model)
          Arel::Nodes::Grouping.new(
            Arel::Nodes::BitwiseNot.new(to_arel_operand(operand, table, model)))
        end
      end
    end
  end
end
