# frozen_string_literal: true

require "active_record/refined/ast/predications"
require "active_record/refined/ast/arithmetics"

module ActiveRecord
  module Refined
    module AST
      # An expression a block has built, whatever it was built from.  The
      # methods here are what every one takes; most subclasses add the
      # conditions of {Predications} and the operators of {Arithmetics}.
      class Node
        # The model travels with the table because some SQL cannot be written
        # without knowing the adapter, and a node is built before anything
        # knows which one it will be rendered for -- a symbol becomes a node
        # inside a refinement, where there is no model to ask.  Most nodes
        # never look at it and only pass it on.
        # @private
        def to_arel(table, model)
          raise ScriptError, "subclass must override this method"
        end

        # The expression under an alias, as {BlockSyntax#as} gives a column
        # one.
        # @return [AST::As]
        def as(alias_name, quote: true)
          As.new(self, alias_name, quote: quote)
        end

        # An ascending ordering by the expression.
        # @return [AST::Ordering]
        def asc
          Ordering.new(self, :asc)
        end

        # A descending ordering by the expression.
        # @return [AST::Ordering]
        def desc
          Ordering.new(self, :desc)
        end

        # The expression under a collation, as {BlockSyntax#collate}.
        # @return [AST::Collate]
        def collate(name)
          Collate.new(self, name)
        end

        private
          # Resolves an operand denoting a column or an expression.  A number
          # rides along for Arel to write out, which it can do for Integer and
          # Float alone: a BigDecimal is quoted, which the adapter spells as
          # the exact decimal, and a Rational, which no decimal spells exactly,
          # is refused.
          def to_arel_operand(operand, table, model)
            case operand
            when Node then operand.to_arel(table, model)
            when :* then Arel.star
            when Symbol then table[operand]
            when ::BigDecimal, ::Rational then quote_number(operand)
            else operand
            end
          end

          # A bare symbol is a column in every position, the value side of a
          # comparison included.  The name is checked against the model, since
          # a name it has no column for is almost always an enum value spelled
          # as a symbol -- which, taken as a column, would quietly compare
          # against nothing anyone meant.
          def column_operand(name, table, model)
            unless model.column_names.include?(name.to_s)
              raise ArgumentError,
                "#{name.inspect} is no column of #{model.table_name}; an enum " \
                "value is written as its string, a column of another table " \
                "qualified"
            end
            table[name]
          end

          # A number compares as itself, the way a bound ? does: the typed path
          # would cast 99.5 against an integer column to 99 and quietly move
          # the boundary.  Everything else keeps the column's own
          # serialization -- an enum's name, a time's zone, a custom type's
          # scaling.
          def quote_number(value)
            case value
            when ::Rational
              raise ArgumentError,
                "a Rational has no exact SQL spelling; to_d says the decimal meant"
            when ::Integer, ::Float, ::BigDecimal
              Arel::Nodes.build_quoted(value)
            else value
            end
          end

          # Resolves a function argument: a column or an expression as above,
          # anything else a value to be quoted.
          def to_arel_argument(arg, table, model)
            case arg
            when Node, Symbol, ::Rational then to_arel_operand(arg, table, model)
            else Arel::Nodes.build_quoted(arg)
            end
          end
      end

      # `&`, `|` and `!` -- AND, OR and NOT, what joins conditions into one
      # and negates them.  A predicate carries them, and so do {Sql} and
      # {Operation}, whose SQL is read as a condition the moment it is
      # combined like one.
      #
      # Included in those three and never imported into a refinement, as
      # {Predications} is: a bare symbol is a column, and a column is not a
      # condition.
      module Connectives
        # `AND`.
        # @return [AST::Predicate]
        # @example
        #   Author.where { :age.between?(20, 40) & (:country == "JP") }
        #   Post.where { sql("score > 0") & (:published == true) }
        def &(other)
          And.new(self, other)
        end

        # `OR`.
        # @return [AST::Predicate]
        def |(other)
          Or.new(self, other)
        end

        # `NOT (condition)`, negating anything; the negations SQL spells for
        # itself, `IS NOT NULL` and its kin, have names of their own under
        # {Predications}.
        # @return [AST::Predicate]
        # @example
        #   Author.where { !:name.like?("A%") }
        #
        # Being here rather than only on Predicate is what keeps `!` on Sql
        # and Operation from falling through to Ruby's own, which would
        # quietly answer false.
        def !
          Not.new(self)
        end
      end

      # A condition: what a comparison or one of the tests gives back, and
      # what `where`, `having` and a join's block hand the relation.
      class Predicate < Node
        include Connectives
      end

      # A literal standing where an expression would: `select { value(0).as(:depth) }`.
      #
      # Values reach the SQL quoted wherever they appear as an operand, but a
      # bare Ruby literal at the top of a select list is refused as saying
      # nothing.  `value` is the spelling that quotes it there, and it carries
      # the predications with it, so a literal can be compared and combined
      # like anything else.
      class Value < Node
        include Predications
        include Arithmetics

        # @private
        attr_reader :value

        def initialize(value)
          @value = value
        end

        # @private
        def to_arel(_table, _model)
          Arel::Nodes.build_quoted(value)
        end
      end

      # SQL as written: `sql("length(name) > ?", 10)`.  The ? and :name
      # placeholders take quoted values through sanitize_sql_array, which
      # needs the connection, so the binds wait here until the model is
      # known.  Without binds the statement passes untouched -- which is
      # what leaves PostgreSQL's ? operators writable, since only the
      # positional-bind rewrite reads ? as a placeholder.
      #
      # As an operand the statement is parenthesized: its precedence is
      # whatever was written inside.  The top of a select list gets it bare,
      # through field_arel, where parentheses would refuse an alias written
      # into the string.
      class Sql < Node
        include Predications
        include Arithmetics
        # After Arithmetics, whose & and | refuse: here they are AND and OR.
        include Connectives

        # @private
        attr_reader :statement, :binds

        def initialize(statement, binds)
          unless statement.is_a?(::String)
            raise ArgumentError,
              "sql takes the statement as a string, not #{statement.inspect}"
          end
          @statement = statement
          @binds = binds
        end

        # @private
        def to_arel(_table, model)
          Arel::Nodes::Grouping.new(field_arel(model))
        end

        # @private
        def field_arel(model)
          return Arel.sql(statement) if binds.empty?

          Arel.sql(model.sanitize_sql_array([statement, *binds]))
        end
      end

      # A column of a named table, which is what `:posts[:author_id]` builds
      # (see {BlockSyntax#[]}): the spelling for another table's column in a
      # join's ON or a query over one.
      class Column < Node
        include Predications
        include Arithmetics

        # @private
        attr_reader :table_name, :column_name

        def initialize(table_name, column_name)
          @table_name = table_name
          @column_name = column_name
        end

        # @private
        def to_arel(_table, _model)
          Arel::Table.new(table_name)[column_name]
        end
      end

      # Escape hatch for operators without a spelling of their own, the way
      # fn is for functions.  The operator is emitted as written -- whether
      # the adapter has it is the caller's assertion, as fn's names are --
      # and the values ride as quoted literals, so on PostgreSQL an untyped
      # one takes the type of the operand beside it.
      class Operation < Node
        include Predications
        include Arithmetics
        # After Arithmetics, whose & and | refuse: here they are AND and OR.
        include Connectives

        # @private
        attr_reader :operator, :left, :right

        def initialize(operator, left, right)
          @operator = AST.check_name(operator, OPERATOR, "operator").to_s
          @left = check_side(left)
          @right = check_side(right)
        end

        # @private
        def to_arel(table, model)
          Arel::Nodes::Grouping.new(
            Arel::Nodes::InfixOperation.new(
              operator, side(left, table, model), side(right, table, model)))
        end

        private
          # An expression operand is parenthesized: an unknown operator's
          # precedence is unknown too, and PostgreSQL reads its named
          # operators from the left, so a bare infix on the right would take
          # the new operator's left side into its own.
          def side(operand, table, model)
            arel = to_arel_argument(operand, table, model)
            operand.is_a?(Node) ? Arel::Nodes::Grouping.new(arel) : arel
          end

          def check_side(operand)
            if operand.is_a?(::Hash) || operand.is_a?(::Array) || operand.is_a?(::Set)
              raise ArgumentError,
                "#{operand.inspect} has no one SQL spelling; a string says it " \
                "in the adapter's own, to_json for a document"
            end
            operand
          end
      end
    end
  end
end
