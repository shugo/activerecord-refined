# frozen_string_literal: true

require "active_record/refined/ast/node"

module ActiveRecord
  module Refined
    module AST
      # A column alias, quoted by the adapter, so that the name asked for is
      # the name that comes back: unquoted, PostgreSQL folds a capital away
      # and the other two keep it, which is one block meaning two things.
      # Quoting also leaves nothing to refuse -- a name that would have been
      # SQL is an identifier with a strange name instead.
      #
      # `quote: false` asks for the name as written, for a schema that wants
      # the folding.
      class As < Node
        # @private
        attr_reader :operand, :alias_name, :quote

        def initialize(operand, alias_name, quote: true)
          # Checked here rather than where the SQL is built, so that a name
          # the adapter is not being asked to quote is refused where it was
          # written.
          AST.check_name(alias_name, ALIAS_NAME, "column alias") unless quote
          @operand = operand
          @alias_name = alias_name
          @quote = quote
        end

        # @private
        def to_arel(table, model)
          to_arel_operand(operand, table, model).as(alias_sql(model))
        end

        private
          def alias_sql(model)
            name = alias_name.to_s
            return name unless quote
            model.with_connection { |connection| connection.quote_column_name(name) }
          end
      end

      # A collation named for a comparison or an ordering: `:name.collate(:ci)`.
      # It stands as an expression -- compared, ordered by, selected -- and
      # gives back one of its own, so the collation carries through.
      #
      # The name follows COLLATE as a bare identifier with no Arel node of its
      # own.  What names are safe turns on whether the family quotes it -- only
      # PostgreSQL does -- so the dialect checks the name as it builds the
      # clause, rather than this node holding one rule for all of them.
      class Collate < Node
        include Predications

        # @private
        attr_reader :operand, :name

        def initialize(operand, name)
          @name = name.to_s
          @operand = operand
        end

        # @private
        def to_arel(table, model)
          Dialect.for(model).collate(to_arel_operand(operand, table, model), name, model)
        end
      end

      # An ordering, `"age" DESC`: a direction on a column or an expression,
      # and through {#nulls_first} and {#nulls_last} a place for the NULLs.
      class Ordering < Node
        # @private
        attr_reader :operand, :direction, :nulls

        def initialize(operand, direction, nulls = nil)
          @operand = operand
          @direction = direction
          @nulls = nulls
        end

        # `NULLS FIRST`; portable, since Arel emulates it where MySQL has
        # none.
        # @return [AST::Ordering]
        #
        # MySQL has no NULLS FIRST/LAST, but Arel emulates it there with a
        # leading IS NULL ordering, so these are portable.
        def nulls_first
          Ordering.new(operand, direction, :nulls_first)
        end

        # `NULLS LAST`.
        # @return [AST::Ordering]
        def nulls_last
          Ordering.new(operand, direction, :nulls_last)
        end

        # @private
        def to_arel(table, model)
          ordering = to_arel_operand(operand, table, model).public_send(direction)
          nulls ? ordering.public_send(nulls) : ordering
        end
      end
    end
  end
end
