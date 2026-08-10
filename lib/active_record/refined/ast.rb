module ActiveRecord
  module Refined
    module AST
      # Column aliases and function names are written into the SQL as given,
      # where a value would have been quoted, so anything that is not a plain
      # name is refused.  Quoting them instead would need the model's adapter,
      # which does not reach this far, and quoting with the wrong one would be
      # a bug of its own -- MySQL does not read "x" as an identifier.
      NAME = /[[:alpha:]_][[:alnum:]_$]*/
      ALIAS_NAME = /\A#{NAME}\z/
      FUNCTION_NAME = /\A#{NAME}(\.#{NAME})?\z/
      # A SQL type as cast writes it: words, at most parenthesized with
      # lengths -- double precision, decimal(10,2).
      TYPE_NAME = /\A[[:alpha:]_][[:alnum:]_ ]*(\(\d+(, ?\d+)?\))?\z/

      def self.check_name(name, pattern, what)
        return name if pattern.match?(name.to_s)
        raise ArgumentError, "#{name.inspect} is not a plain #{what}"
      end

      # Predicate builders shared by symbols, qualified columns and
      # expressions. Imported into the Symbol refinement with
      # Refinement#import_methods, so every method must be defined with def.
      module Predications
        # == and != mean SQL = and <>, and = NULL is never true there, so nil
        # is rejected rather than silently rewritten to IS NULL.  null? builds
        # its node directly and stays clear of this check.
        def ==(other)
          if other.nil?
            raise ArgumentError, "== does not take nil; use null? instead"
          end
          Comparison.new(self, :==, other)
        end

        def !=(other)
          if other.nil?
            raise ArgumentError, "!= does not take nil; use !null? instead"
          end
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

        def ilike?(pattern)
          Like.new(self, pattern, nil, case_sensitive: false)
        end

        # Case-insensitive equality, folded on both sides rather than left to
        # the collation, so it means the same thing on every adapter.
        def casecmp?(value)
          if value.nil?
            raise ArgumentError, "casecmp? does not take nil; use null? instead"
          end
          Comparison.new(Function.new("LOWER", [self]), :==,
                         Function.new("LOWER", [value]))
        end

        # Null-safe comparison: unlike = and <>, these treat NULL as a value,
        # so not_distinct_from? is the one equality that may take nil.
        def distinct_from?(value)
          DistinctFrom.new(self, value, negated: true)
        end

        def not_distinct_from?(value)
          DistinctFrom.new(self, value)
        end

        def start_with?(*prefixes)
          if prefixes.empty?
            raise ArgumentError, "start_with? needs at least one prefix"
          end
          Like.any(self, prefixes.map {|prefix| "#{Like.escape(prefix)}%" })
        end

        def end_with?(*suffixes)
          if suffixes.empty?
            raise ArgumentError, "end_with? needs at least one suffix"
          end
          Like.any(self, suffixes.map {|suffix| "%#{Like.escape(suffix)}" })
        end

        def include?(substring)
          Like.new(self, "%#{Like.escape(substring)}%", Like::ESCAPE)
        end

        # The array comparisons carry the meaning of their Ruby namesakes.
        # member? is Enumerable's element test, so an Array argument is
        # rejected rather than quietly meaning something Array#member? does
        # not; whole-array comparisons go by the Set and Array names.
        def member?(element)
          if element.is_a?(::Array) || element.is_a?(::Set)
            raise ArgumentError,
              "member? takes a single element; use superset? to require every element"
          end
          ArrayPredicate.new(self, :"@>", [element])
        end

        def superset?(elements)
          ArrayPredicate.new(self, :"@>", ArrayPredicate.elements(elements, "superset?"))
        end

        def subset?(elements)
          ArrayPredicate.new(self, :"<@", ArrayPredicate.elements(elements, "subset?"))
        end

        def intersect?(elements)
          ArrayPredicate.new(self, :"&&", ArrayPredicate.elements(elements, "intersect?"))
        end
      end

      # Arithmetic builders shared by symbols, qualified columns and
      # expressions.  Imported into the Symbol refinement like Predications,
      # so every method must be defined with def.
      module Arithmetics
        def +(other)
          Arithmetic.new(self, :+, other)
        end

        def -(other)
          Arithmetic.new(self, :-, other)
        end

        def *(other)
          Arithmetic.new(self, :*, other)
        end

        def /(other)
          Arithmetic.new(self, :/, other)
        end
      end

      # Aggregate builders shared by symbols, qualified columns and
      # expressions.  Imported into the Symbol refinement like Predications,
      # so every method must be defined with def.
      module Aggregations
        # DISTINCT is Arel's only aggregate modifier, and only for count.
        def count(distinct: false)
          Aggregate.new(self, :count, distinct: distinct)
        end

        def sum
          Aggregate.new(self, :sum)
        end

        def average
          Aggregate.new(self, :average)
        end

        def maximum
          Aggregate.new(self, :maximum)
        end

        def minimum
          Aggregate.new(self, :minimum)
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

        # Resolves a function argument: a column or an expression as above,
        # anything else a value to be quoted.
        def to_arel_argument(arg, table)
          case arg
          when Node, Symbol then to_arel_operand(arg, table)
          else Arel::Nodes.build_quoted(arg)
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

      # A literal standing where an expression would: `select { value(0).as(:depth) }`.
      #
      # Values reach the SQL quoted wherever they appear as an operand, but the
      # top of a select list is ActiveRecord's, and a bare string there is SQL
      # rather than a string.  Saying `value` is how you ask for the other
      # meaning, and it carries the predications with it, so a literal can be
      # compared and combined like anything else.
      class Value < Node
        include Predications
        include Arithmetics
        include Aggregations

        attr_reader :value

        def initialize(value)
          @value = value
        end

        def to_arel(_table)
          Arel::Nodes.build_quoted(value)
        end
      end

      class Column < Node
        include Predications
        include Arithmetics
        include Aggregations

        attr_reader :table_name, :column_name

        def initialize(table_name, column_name)
          @table_name = table_name
          @column_name = column_name
        end

        def to_arel(_table)
          Arel::Table.new(table_name)[column_name]
        end
      end

      # Arithmetic on columns and expressions.  Ruby's precedence puts these
      # above the comparison operators, so :price * :quantity > 100 groups the
      # way it reads.
      class Arithmetic < Node
        include Predications
        include Arithmetics
        include Aggregations

        attr_reader :left, :operator, :right

        def initialize(left, operator, right)
          @left = left
          @operator = operator
          @right = right
        end

        def to_arel(table)
          to_arel_operand(left, table).
            public_send(operator, to_arel_operand(right, table))
        end
      end

      class Aggregate < Node
        include Predications
        include Arithmetics

        attr_reader :operand, :function, :distinct

        def initialize(operand, function, distinct: false)
          if distinct && function != :count
            raise ArgumentError, "#{function} does not take distinct"
          end
          if distinct && operand == :*
            raise ArgumentError, "count(:*) does not take distinct; name a column"
          end
          @operand = operand
          @function = function
          @distinct = distinct
        end

        def to_arel(table)
          arel_operand = to_arel_operand(operand, table)
          if function == :count
            arel_operand.count(distinct)
          else
            arel_operand.public_send(function)
          end
        end
      end

      class As < Node
        attr_reader :operand, :alias_name

        def initialize(operand, alias_name)
          @operand = operand
          @alias_name = AST.check_name(alias_name, ALIAS_NAME, "column alias")
        end

        def to_arel(table)
          to_arel_operand(operand, table).as(alias_name.to_s)
        end
      end

      class Ordering < Node
        attr_reader :operand, :direction, :nulls

        def initialize(operand, direction, nulls = nil)
          @operand = operand
          @direction = direction
          @nulls = nulls
        end

        # MySQL has no NULLS FIRST/LAST, but Arel emulates it there with a
        # leading IS NULL ordering, so these are portable.
        def nulls_first
          Ordering.new(operand, direction, :nulls_first)
        end

        def nulls_last
          Ordering.new(operand, direction, :nulls_last)
        end

        def to_arel(table)
          ordering = to_arel_operand(operand, table).public_send(direction)
          nulls ? ordering.public_send(nulls) : ordering
        end
      end

      class Function < Node
        include Predications
        include Arithmetics

        attr_reader :name, :args

        def initialize(name, args)
          @name = name
          @args = args
        end

        def to_arel(table)
          arel_args = args.map {|arg| to_arel_argument(arg, table) }
          Arel::Nodes::NamedFunction.new(name, arel_args)
        end
      end

      # EXTRACT(field FROM expr).  The field is grammar rather than a value --
      # a keyword the adapter reads bare -- so it has to be a plain name,
      # which Arel upcases on the way out.
      class Extract < Node
        include Predications
        include Arithmetics

        attr_reader :field, :operand

        def initialize(field, operand)
          @field = AST.check_name(field, ALIAS_NAME, "extract field")
          @operand = operand
        end

        def to_arel(table)
          Arel::Nodes::Extract.new(to_arel_argument(operand, table), field.to_s)
        end
      end

      # CAST(expr AS type).  The type is grammar too, written into the SQL as
      # given -- it is the adapter's own name for the type, and whether it
      # exists is the database's to say -- so it has to look like one:
      # a plain name, at most parenthesized with lengths.
      class Cast < Node
        include Predications
        include Arithmetics

        attr_reader :operand, :sql_type

        def initialize(operand, sql_type)
          @operand = operand
          @sql_type = AST.check_name(sql_type, TYPE_NAME, "SQL type")
        end

        def to_arel(table)
          Arel::Nodes::NamedFunction.new(
            "CAST",
            [Arel::Nodes::As.new(to_arel_argument(operand, table),
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

        attr_reader :name, :precision

        def initialize(name, precision = nil)
          unless precision.nil? || precision.is_a?(Integer)
            raise ArgumentError,
              "#{precision.inspect} is not an Integer precision"
          end
          @name = name
          @precision = precision
        end

        def to_arel(_table)
          Arel::Nodes::SqlLiteral.new(
            precision ? "#{name}(#{precision})" : name)
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
          arel_value =
            case value
            when Node then value.to_arel(table)
            when ActiveRecord::Relation then scalar_subquery(value)
            else value
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

      # IN for a list of values, BETWEEN for a range, IN (SELECT ...) for a
      # relation.
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
          when ActiveRecord::Relation then arel_operand.in(subquery(values))
          else arel_operand.in(values)
          end
        end

        private

        # The same treatment ActiveRecord's own RelationHandler gives a
        # relation used as a value: without an explicit select list the
        # subquery selects the model's primary key.
        def subquery(relation)
          if relation.eager_loading?
            relation = relation.send(:apply_join_dependency)
          end
          if relation.select_values.empty?
            model = relation.model
            if model.composite_primary_key?
              raise ArgumentError,
                "Cannot map composite primary key #{model.primary_key} to IN"
            end
            relation = relation.select(relation.table[model.primary_key])
          end
          relation.arel
        end
      end

      # EXISTS (SELECT ...) for a relation.  Correlate the subquery with the
      # outer table through qualified columns.  EXISTS only asks whether a row
      # comes back, so unlike In there is no select list to fix up.
      class Exists < Predicate
        attr_reader :relation

        def initialize(relation)
          @relation = relation
        end

        def to_arel(_table)
          subquery = relation
          if subquery.eager_loading?
            subquery = subquery.send(:apply_join_dependency)
          end
          subquery.arel.exists
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

        # ORs one LIKE per pattern, for the shortcuts that accept several
        # literals the way String#start_with? does.
        def self.any(operand, patterns)
          patterns.map {|pattern| new(operand, pattern, ESCAPE) }.
            inject {|left, right| Or.new(left, right) }
        end

        attr_reader :operand, :pattern, :escape, :case_sensitive

        def initialize(operand, pattern, escape = nil, case_sensitive: true)
          @operand = operand
          @pattern = pattern
          @escape = escape
          @case_sensitive = case_sensitive
        end

        def to_arel(table)
          # Arel matches case-insensitively unless told otherwise, which is
          # what picks ILIKE over LIKE on PostgreSQL.
          to_arel_operand(operand, table).matches(pattern, escape, case_sensitive)
        end
      end

      # IS [NOT] DISTINCT FROM, spelled IS / IS NOT on SQLite and <=> on
      # MySQL.  NULL compares as a value here, which is what separates these
      # from = and <>.
      class DistinctFrom < Predicate
        attr_reader :operand, :value, :negated

        def initialize(operand, value, negated: false)
          @operand = operand
          @value = value
          @negated = negated
        end

        def to_arel(table)
          arel_operand = to_arel_operand(operand, table)
          arel_value = value.is_a?(Node) ? value.to_arel(table) : value
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
        def self.elements(arg, method_name)
          case arg
          when ::Array then arg
          when ::Set then arg.to_a
          else
            raise ArgumentError, "#{method_name} takes an Array or Set of elements"
          end
        end

        attr_reader :operand, :operator, :elements

        def initialize(operand, operator, elements)
          @operand = operand
          @operator = operator
          @elements = elements
        end

        def to_arel(table)
          arel_operand = to_arel_operand(operand, table)
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
