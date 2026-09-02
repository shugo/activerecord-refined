# frozen_string_literal: true

module ActiveRecord
  module Refined
    module AST
      # The arithmetic and the bitwise operations on a column or an
      # expression.  Ruby puts the operators above the comparisons, so
      # `:price * :quantity > 100` groups the way it reads, and a number on
      # the left -- `20 - :quantity` -- builds the same expression.
      #
      # Bitwise AND and OR are named, not spelled `&` and `|`: those two are
      # AND and OR between conditions and mean nothing else anywhere.  The
      # rest keep their operators, with {#bitwise_xor} and {#bitwise_not}
      # beside `^` and `~` for a reader who would rather have the name.
      # Oracle, which has no bitwise operators at all, refuses every one.
      #
      # @example
      #   LineItem.where { :price * :quantity > 1000 }
      #   LineItem.select { :flags.bitwise_and(4).as(:featured) }
      #
      # Arithmetic builders shared by symbols, qualified columns and
      # expressions.  Imported into the Symbol refinement like Predications,
      # so every method must be defined with def.
      module Arithmetics
        # `+`; with an Active Support duration on the right, a date moved: `:due_on + 3.days`.
        # @return [AST::Arithmetic]
        def +(other)
          Arithmetic.new(self, :+, other)
        end

        # `-`; with a duration on the right, a date moved back.
        # @return [AST::Arithmetic]
        def -(other)
          Arithmetic.new(self, :-, other)
        end

        # `*`.
        # @return [AST::Arithmetic]
        def *(other)
          Arithmetic.new(self, :*, other)
        end

        # `/`.
        # @return [AST::Arithmetic]
        def /(other)
          Arithmetic.new(self, :/, other)
        end

        # `&` is AND, and a column is not a condition, so this refuses:
        # {#bitwise_and} is the SQL operator, and `.true?` makes a boolean
        # column a condition.
        # @raise [ArgumentError]
        def &(other)
          AST.refuse_logical(:&, "AND", "bitwise_and", other)
        end

        # `|` is OR, and refuses here as `&` does.
        # @raise [ArgumentError]
        def |(other)
          AST.refuse_logical(:|, "OR", "bitwise_or", other)
        end

        # Bitwise AND: `"flags" & 4`.  It is spelled as a name because `&`
        # is AND, and a method binds tighter than any comparison, so nothing
        # has to be parenthesised to be compared.
        # @return [AST::Bitwise]
        # @example
        #   Post.where { :flags.bitwise_and(4) > 0 }
        def bitwise_and(other)
          Bitwise.new(self, :&, other)
        end

        # Bitwise OR.
        # @return [AST::Bitwise]
        def bitwise_or(other)
          Bitwise.new(self, :|, other)
        end

        # Bitwise XOR: `#` on PostgreSQL, `^` on MySQL, and the two operations it is made of on SQLite.
        # @return [AST::Bitwise]
        def ^(other)
          Bitwise.new(self, :^, other)
        end

        # {#^} under a name.
        # @return [AST::Bitwise]
        def bitwise_xor(other)
          Bitwise.new(self, :^, other)
        end

        # A shift left.
        # @return [AST::Bitwise]
        def <<(other)
          Bitwise.new(self, :<<, other)
        end

        # A shift right.
        # @return [AST::Bitwise]
        def >>(other)
          Bitwise.new(self, :>>, other)
        end

        # Bitwise NOT.
        # @return [AST::BitwiseNot]
        def ~
          BitwiseNot.new(self)
        end

        # {#~} under a name.  `!` is not the one to reach for: it is Ruby's
        # own on a column and answers `false`, which no query ever wanted.
        # @return [AST::BitwiseNot]
        def bitwise_not
          BitwiseNot.new(self)
        end
      end

      # Arithmetic with the number on the left, imported into the numeric
      # refinements: 20 - :quantity builds what :quantity + 20 builds.  Only
      # a column or an expression on the right means a query; anything else
      # goes back to the number through super, so 1 + 2 is 3 inside a block
      # too, and 4 & 5 is 4.  & and | refuse a query the way they do on a
      # column, bitwise_and and its kin carrying those two operations.
      # @private
      module NumericArithmetics
        def +(other)
          return super unless other.is_a?(::Symbol) || other.is_a?(Node)
          Arithmetic.new(self, :+, other)
        end

        def -(other)
          return super unless other.is_a?(::Symbol) || other.is_a?(Node)
          Arithmetic.new(self, :-, other)
        end

        def *(other)
          return super unless other.is_a?(::Symbol) || other.is_a?(Node)
          Arithmetic.new(self, :*, other)
        end

        def /(other)
          return super unless other.is_a?(::Symbol) || other.is_a?(Node)
          Arithmetic.new(self, :/, other)
        end

        def &(other)
          return super unless other.is_a?(::Symbol) || other.is_a?(Node)
          AST.refuse_logical(:&, "AND", "bitwise_and", other)
        end

        def |(other)
          return super unless other.is_a?(::Symbol) || other.is_a?(Node)
          AST.refuse_logical(:|, "OR", "bitwise_or", other)
        end

        def ^(other)
          return super unless other.is_a?(::Symbol) || other.is_a?(Node)
          Bitwise.new(self, :^, other)
        end

        def <<(other)
          return super unless other.is_a?(::Symbol) || other.is_a?(Node)
          Bitwise.new(self, :<<, other)
        end

        def >>(other)
          return super unless other.is_a?(::Symbol) || other.is_a?(Node)
          Bitwise.new(self, :>>, other)
        end

        def bitwise_and(other)
          Bitwise.new(self, :&, other)
        end

        def bitwise_or(other)
          Bitwise.new(self, :|, other)
        end

        def bitwise_xor(other)
          Bitwise.new(self, :^, other)
        end
      end
    end
  end
end
