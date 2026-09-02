# frozen_string_literal: true

require "active_record/refined/ast/predications"
require "active_record/refined/ast/arithmetics"
require "active_record/refined/ast/node"
require "active_record/refined/ast/expressions"
require "active_record/refined/ast/windows"
require "active_record/refined/ast/functions"
require "active_record/refined/ast/json"
require "active_record/refined/ast/ordering"
require "active_record/refined/ast/grouping"
require "active_record/refined/ast/conditions"

module ActiveRecord
  module Refined
    # The nodes a block's expressions build, compiled to Arel when the
    # relation writes its SQL.  What a user writes is the methods of
    # {Predications}, {Arithmetics}, {BlockSyntax} and {BlockContext};
    # what those give back is a node here.
    module AST
      # @private
      NAME = /[[:alpha:]_][[:alnum:]_$]*/
      # @private
      ALIAS_NAME = /\A#{NAME}\z/
      # @private
      FUNCTION_NAME = /\A#{NAME}(\.#{NAME})?\z/
      # A collation name where the family writes it bare, as all but PostgreSQL
      # do.  A plain identifier: a hyphen unquoted would read as the collation
      # minus a number, `x COLLATE nocase-1` as `(x COLLATE nocase) - 1`, valid
      # and wrong.  PostgreSQL quotes the name and widens this; see its dialect.
      # @private
      COLLATION_NAME = /\A#{NAME}\z/
      # A SQL type as cast writes it: words, at most parenthesized with
      # lengths -- double precision, decimal(10,2).
      # @private
      TYPE_NAME = /\A[[:alpha:]_][[:alnum:]_ ]*(\(\d+(, ?\d+)?\))?\z/
      # The characters PostgreSQL allows an operator to be made of, the
      # widest operator alphabet of the three; op admits nothing else, so a
      # letter, a space or a quote never reaches the SQL as an operator.
      # @private
      OPERATOR = %r{\A[+\-*/<>=~!@\#%^&|`?]+\z}

      # @private
      def self.check_name(name, pattern, what)
        return name if pattern.match?(name.to_s)
        raise ArgumentError, "#{name.inspect} is not a plain #{what}"
      end

      # Whether a node is one of the three things a condition can be: a
      # predicate, or either of the escape hatches, which are conditions
      # whenever what was written inside them is one.
      # @private
      def self.condition?(node)
        node.is_a?(Predicate) || node.is_a?(Sql) || node.is_a?(Operation)
      end

      # @private
      def self.check_condition(node, operator)
        return node if condition?(node)
        raise ArgumentError,
          "#{operator} joins conditions; " \
          "#{node.is_a?(Node) ? 'an expression' : node.inspect} is not one"
      end

      # What true, false and nil say when `&`, `|` or `^` finds a query node
      # on the right.  Their own operators answer a bare boolean, so in
      # `:active == true & cond` Ruby gives `:active == (true & cond)` and
      # the condition would vanish from the query without a word; a number
      # in the same place lands in NumericArithmetics' refusals, but these
      # three have no bitwise reading to fall back on.
      # @private
      def self.refuse_ruby_operator(literal, operator)
        raise ArgumentError,
          "#{operator} on #{literal.inspect} is Ruby's own, and the query " \
          "would lose what stands to its right; the comparison takes " \
          "parentheses of its own: (:active == true) #{operator} ..."
      end

      # What `&` and `|` say when the left side is not a condition.  They
      # mean AND and OR, so what was meant is either the bitwise operation,
      # which has a name of its own, or a comparison whose parentheses Ruby's
      # precedence ate; which one it is the other operand tells.
      # @private
      def self.refuse_logical(operator, logical, named, operand)
        raise ArgumentError,
          if condition?(operand)
            "#{operator} joins conditions, and the left side is not one; " \
            "a comparison there needs parentheses of its own: " \
            "(:age >= 18) #{operator} ..."
          else
            "#{operator} between conditions is #{logical}; " \
            "#{named} is SQL's bitwise operator"
          end
      end
    end
  end
end
