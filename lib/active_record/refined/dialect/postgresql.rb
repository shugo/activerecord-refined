# frozen_string_literal: true

module ActiveRecord
  module Refined
    class Dialect
      # PostgreSQL, and the adapters that answer for the same server.
      class Postgresql < Dialect
        # PostgreSQL counts the bits of a bit string rather than a number, so
        # the argument is cast, to bit(64) for a negative to come back as the
        # MySQL family has it.
        def bit_count(expr, _model)
          AST::Function.new("BIT_COUNT", [AST::Cast.new(expr, "bit(64)")])
        end

        # PostgreSQL's XOR is #, where ^ is exponentiation.
        def bitwise_xor(left, right)
          Arel::Nodes::InfixOperation.new("#", left, right)
        end
      end
    end
  end
end
