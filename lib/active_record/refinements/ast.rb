module ActiveRecord
  module Refinements
    module AST
      class Node
        def to_arel(table)
          raise ScriptError, "subclass must override this method"
        end
      end

      class Predicate < Node
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
          table[column].public_send(OPERATOR_MAP.fetch(operator), value)
        end
      end
    end
  end
end
