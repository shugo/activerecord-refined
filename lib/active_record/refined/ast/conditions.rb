# frozen_string_literal: true

require "active_record/refined/ast/node"

module ActiveRecord
  module Refined
    module AST
      # A plain SQL comparison. The value is passed through as it is, so a Range
      # or an Array compares against a PostgreSQL range or array column, the way
      # Active Record's own force_equality? types do.
      class Comparison < Predicate
        # @private
        OPERATOR_MAP = {
          :== => :eq, :!= => :not_eq,
          :> => :gt, :>= => :gteq, :< => :lt, :<= => :lteq
        }.freeze

        # @private
        attr_reader :column, :operator, :value

        def initialize(column, operator, value)
          @column = column
          @operator = operator
          @value = value
        end

        # @private
        def to_arel(table, model)
          arel_column = to_arel_operand(column, table, model)
          arel_value =
            case value
            when Node then value.to_arel(table, model)
            when ::Symbol then column_operand(value, table, model)
            when ActiveRecord::Relation then scalar_subquery(value)
            else quote_number(value)
            end
          arel_column.public_send(OPERATOR_MAP.fetch(operator), arel_value)
        end

        private
          # A relation compared against a column has to yield a single value, so
          # unlike In there is no sensible default select list to fall back on.
          def scalar_subquery(relation)
            if relation.select_values.empty?
              raise ArgumentError,
                "#{operator} needs a subquery selecting one value; add a select"
            end
            relation = relation.send(:apply_join_dependency) if relation.eager_loading?
            relation.arel
          end
      end

      # IS TRUE, IS FALSE and their negations, which every adapter spells the
      # same way and answers alike, NULL included.
      class TruthValue < Predicate
        # @private
        attr_reader :operand, :value, :negated

        def initialize(operand, value, negated: false)
          @operand = operand
          @value = value
          @negated = negated
        end

        # @private
        def to_arel(table, model)
          Dialect.for(model).truth_value(
            to_arel_operand(operand, table, model), value, negated, model)
        end
      end

      # A relation standing for a set of values, which is what IN and the
      # quantifiers each take.  The treatment is Active Record's own
      # RelationHandler's: without an explicit select list the subquery
      # selects the model's primary key.
      # @private
      module SetSubquery
        private
          def set_subquery(relation, spelling)
            relation = relation.send(:apply_join_dependency) if relation.eager_loading?
            if relation.select_values.empty?
              model = relation.model
              if model.composite_primary_key?
                raise ArgumentError,
                  "Cannot map composite primary key #{model.primary_key} to #{spelling}"
              end
              relation = relation.select(relation.table[model.primary_key])
            end
            relation.arel
          end
      end

      # IN for a list of values, BETWEEN for a range, IN (SELECT ...) for a
      # relation.
      class In < Predicate
        include SetSubquery

        # Range holds its endpoints to Comparable, which a quoted node is
        # not, so this quacks the three methods Arel's between reads.
        # @private
        QuotedRange = Struct.new(:begin, :end, :exclude_end) do
          def exclude_end? = exclude_end
        end

        # @private
        attr_reader :operand, :values, :negated

        def initialize(operand, values, negated: false)
          @operand = operand
          @values = values
          @negated = negated
        end

        # @private
        def to_arel(table, model)
          arel_operand = to_arel_operand(operand, table, model)
          case values
          when Range, QuotedRange
            lower = quote_value(values.begin, table, model)
            upper = quote_value(values.end, table, model)
            if json_between?(model) && lower && upper && !negated
              return arel_operand.gteq(lower).and(
                values.exclude_end? ? arel_operand.lt(upper) : arel_operand.lteq(upper))
            end
            range = QuotedRange.new(lower, upper, values.exclude_end?)
            arel_operand.public_send(negated ? :not_between : :between, range)
          when ActiveRecord::Relation
            arel_operand.public_send(negated ? :not_in : :in, set_subquery(values, "IN"))
          else
            arg = values
            if arg.is_a?(::Array)
              arg = arg.map { |value| quote_value(value, table, model) }
              return json_list(arel_operand, arg) if json_list?(model)
            end
            arel_operand.public_send(negated ? :not_in : :in, arg)
          end
        end

        private
          # An element that is already an expression resolves, a symbol is a
          # column here as everywhere, a number is quoted as itself, and the
          # rest ride for Arel to cast by the column.
          def quote_value(value, table, model)
            case value
            when Node then value.to_arel(table, model)
            when ::Symbol then column_operand(value, table, model)
            else quote_number(value)
            end
          end

          # MySQL leaves IN and BETWEEN out of its JSON comparisons -- they
          # fall back to another comparison entirely -- so on it a JSON set is
          # spelled as the comparisons it means: the closed range as its two
          # bounds, the list as one equality per element.  That names the dug
          # value once per element, the price SQLite's XOR pays per operand;
          # a negated range needs nothing, Arel writing it as two comparisons
          # everywhere.  MariaDB never gets this far: the endpoints refuse as
          # they resolve.
          def json_between?(model)
            (values.begin.is_a?(JsonLiteral) || values.end.is_a?(JsonLiteral)) &&
              Dialect.for(model).json_list_by_element?
          end

          def json_list?(model)
            values.any? { |value| value.is_a?(JsonLiteral) } &&
              Dialect.for(model).json_list_by_element?
          end

          def json_list(arel_operand, elements)
            comparisons = elements.map do |element|
              negated ? arel_operand.not_eq(element) : arel_operand.eq(element)
            end
            joined = comparisons.inject do |so_far, piece|
              negated ? so_far.and(piece) : so_far.or(piece)
            end
            negated ? Arel::Nodes::Grouping.new(joined) : joined
          end
      end

      # ANY and ALL, which stand on the right of a comparison and say how many
      # of the subquery's rows have to satisfy it.  Where a scalar subquery
      # has to return one row, these take as many as come.
      class Quantified < Node
        include SetSubquery

        # @private
        attr_reader :kind, :relation

        def initialize(kind, relation)
          unless relation.is_a?(ActiveRecord::Relation)
            raise ArgumentError,
              "#{kind} takes a relation as its subquery; a list is what in? takes"
          end
          @kind = kind
          @relation = relation
        end

        # The subquery goes in as its own AST rather than as the manager,
        # which would parenthesise it a second time -- and to PostgreSQL
        # `ANY ((SELECT ...))` is ANY of one scalar, which it refuses.
        # @private
        def to_arel(_table, _model)
          Arel::Nodes::NamedFunction.new(kind, [set_subquery(relation, kind).ast])
        end
      end

      # EXISTS (SELECT ...) for a relation.  Correlate the subquery with the
      # outer table through qualified columns.  EXISTS only asks whether a row
      # comes back, so unlike In there is no select list to fix up.
      class Exists < Predicate
        # @private
        attr_reader :relation

        def initialize(relation)
          @relation = relation
        end

        # @private
        def to_arel(_table, _model)
          subquery = relation
          if subquery.eager_loading?
            subquery = subquery.send(:apply_join_dependency)
          end
          subquery.arel.exists
        end
      end

      # `LIKE`, negated or case-insensitive as asked.  The pattern of
      # {Predications#like?} goes as written, `%` and `_` its wildcards; the
      # shortcuts, {Predications#start_with?} and its kin, escape theirs and
      # say so with `ESCAPE`, since SQLite reads no escape character unless
      # told one.
      class Like < Predicate
        # @private
        ESCAPE = "\\"

        # Escapes % and _ so that they match literally. The pattern built from
        # the result must be used with ESCAPE, since SQLite has no default
        # escape character.
        # @private
        def self.escape(string)
          ActiveRecord::Base.sanitize_sql_like(string, ESCAPE)
        end

        # ORs one LIKE per pattern, for the shortcuts that accept several
        # literals the way String#start_with? does.
        # @private
        def self.any(operand, patterns)
          patterns.map { |pattern| new(operand, pattern, ESCAPE) }.
            inject { |left, right| Or.new(left, right) }
        end

        # @private
        attr_reader :operand, :pattern, :escape, :case_sensitive, :negated

        def initialize(operand, pattern, escape = nil, case_sensitive: true,
                       negated: false)
          @operand = operand
          @pattern = pattern
          @escape = escape
          @case_sensitive = case_sensitive
          @negated = negated
        end

        # @private
        def to_arel(table, model)
          # Arel matches case-insensitively unless told otherwise, which is
          # what picks ILIKE over LIKE on PostgreSQL.
          to_arel_operand(operand, table, model).
            public_send(negated ? :does_not_match : :matches,
                        pattern, escape, case_sensitive)
        end
      end

      # IS [NOT] DISTINCT FROM, spelled IS / IS NOT on SQLite and <=> on
      # MySQL.  NULL compares as a value here, which is what separates these
      # from = and <>.
      class DistinctFrom < Predicate
        # @private
        attr_reader :operand, :value, :negated

        def initialize(operand, value, negated: false)
          @operand = operand
          @value = value
          @negated = negated
        end

        # @private
        def to_arel(table, model)
          arel_operand = to_arel_operand(operand, table, model)
          arel_value = value.is_a?(Node) ? value.to_arel(table, model) : value
          if negated
            arel_operand.is_distinct_from(arel_value)
          else
            arel_operand.is_not_distinct_from(arel_value)
          end
        end
      end

      # Comparisons against a PostgreSQL array column, named after the Ruby
      # methods that mean the same thing: member? is Enumerable's element
      # test, superset? and subset? are Set's whole-array containment, and
      # intersect? is Array's "any element in common".  Each name maps to one
      # operator; the elements are rendered as an array literal, which
      # PostgreSQL coerces to the column's element type, so any expression
      # works as the operand and no schema lookup is needed.
      class ArrayPredicate < Predicate
        # The whole-array comparisons take the collection kinds their
        # namesakes compare against: an Array, or a Set for the Set methods.
        # @private
        def self.elements(arg, method_name)
          case arg
          when ::Array then arg
          when ::Set then arg.to_a
          else
            raise ArgumentError, "#{method_name} takes an Array or Set of elements"
          end
        end

        # @private
        attr_reader :operand, :operator, :elements

        def initialize(operand, operator, elements)
          @operand = operand
          @operator = operator
          @elements = elements
        end

        # @private
        #
        # The refusal is the gem's rather than Arel's: the visitor stopped
        # @> and && off PostgreSQL, but <@ rode an InfixOperation and
        # rendered anywhere, so subset? alone reached the other servers.
        def to_arel(table, model)
          unless Dialect.for(model).array_comparisons_supported?
            raise NotImplementedError,
              "the array comparisons have no equivalent on " \
              "#{model.connection_db_config.adapter}"
          end
          arel_operand = to_arel_operand(operand, table, model)
          quoted = Arel::Nodes.build_quoted(array_literal)
          case operator
          when :"@>" then Arel::Nodes::Contains.new(arel_operand, quoted)
          when :"&&" then Arel::Nodes::Overlaps.new(arel_operand, quoted)
          else Arel::Nodes::InfixOperation.new(operator, arel_operand, quoted)
          end
        end

        private
          # PostgreSQL array input syntax: elements joined by commas inside
          # braces, and an element is double-quoted whenever it is empty, spells
          # NULL, or contains a character the parser treats specially.
          def array_literal
            encoded = elements.map do |value|
              s = value.to_s
              if s.empty? || s.casecmp?("null") || s.match?(/[\s{},"\\]/)
                "\"#{s.gsub(/["\\]/) { |c| "\\#{c}" }}\""
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
        # @private
        attr_reader :operand, :pattern, :negated

        def initialize(operand, pattern, negated: false)
          @operand = operand
          @pattern = pattern.is_a?(Regexp) ? regexp_source(pattern) : pattern
          @negated = negated
        end

        # @private
        def to_arel(table, model)
          arel_operand = to_arel_operand(operand, table, model)
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

      # `AND`, which `&` between two conditions builds.
      class And < Predicate
        # @private
        attr_reader :left, :right

        def initialize(left, right)
          @left = AST.check_condition(left, :&)
          @right = AST.check_condition(right, :&)
        end

        # @private
        def to_arel(table, model)
          left.to_arel(table, model).and(right.to_arel(table, model))
        end
      end

      # `OR`, which `|` between two conditions builds.
      class Or < Predicate
        # @private
        attr_reader :left, :right

        def initialize(left, right)
          @left = AST.check_condition(left, :|)
          @right = AST.check_condition(right, :|)
        end

        # @private
        def to_arel(table, model)
          left.to_arel(table, model).or(right.to_arel(table, model))
        end
      end

      # `NOT`, which `!` on a condition builds.
      class Not < Predicate
        # @private
        attr_reader :operand

        def initialize(operand)
          @operand = AST.check_condition(operand, :!)
        end

        # @private
        def to_arel(table, model)
          Arel::Nodes::Not.new(operand.to_arel(table, model))
        end
      end
    end
  end
end
