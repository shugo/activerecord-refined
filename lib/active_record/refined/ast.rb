# frozen_string_literal: true

# JSON.generate, for the document a containment test is given.
require "json"

module ActiveRecord
  module Refined
    module AST
      NAME = /[[:alpha:]_][[:alnum:]_$]*/
      ALIAS_NAME = /\A#{NAME}\z/
      FUNCTION_NAME = /\A#{NAME}(\.#{NAME})?\z/
      # A SQL type as cast writes it: words, at most parenthesized with
      # lengths -- double precision, decimal(10,2).
      TYPE_NAME = /\A[[:alpha:]_][[:alnum:]_ ]*(\(\d+(, ?\d+)?\))?\z/

      # Which family of spellings an adapter belongs to.  MariaDB answers to
      # the mysql2 adapter and is counted with MySQL, though the two part
      # company over JSON.  An adapter nobody has classified keeps the
      # standard spellings and is left to say for itself what it cannot do.
      #
      # pglite is PostgreSQL itself compiled to WebAssembly, reached through
      # wasmify-rails' adapter; the server it answers for is the same one.
      ADAPTER_FAMILIES = {
        "sqlite3" => :sqlite,
        "postgresql" => :postgresql,
        "postgis" => :postgresql,
        "pglite" => :postgresql,
        "mysql2" => :mysql,
        "trilogy" => :mysql,
      }.freeze

      def self.adapter_family(model)
        ADAPTER_FAMILIES[model.connection_db_config.adapter] || :unknown
      end

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

        # `!` negates any predicate, so these are here for the four that SQL
        # spells for itself: IS NOT NULL rather than NOT (... IS NULL), and
        # likewise NOT IN and NOT LIKE.  They mean the same thing either way,
        # including when the column is NULL; what they save is the reading.
        def null?
          Comparison.new(self, :==, nil)
        end

        def not_null?
          Comparison.new(self, :!=, nil)
        end

        # IS TRUE and IS FALSE differ from a comparison against the literal in
        # what they make of NULL: `flag = TRUE` is itself NULL there, and a
        # NULL predicate selects nothing, while these two answer false.  So the
        # difference shows in the negations: `not_true?` keeps the NULL rows
        # that `!(:flag == true)` drops.
        def true?
          TruthValue.new(self, true)
        end

        def not_true?
          TruthValue.new(self, true, negated: true)
        end

        def false?
          TruthValue.new(self, false)
        end

        def not_false?
          TruthValue.new(self, false, negated: true)
        end

        def in?(values)
          In.new(self, values)
        end

        def not_in?(values)
          In.new(self, values, negated: true)
        end

        # Not min..max: an endpoint may be an expression, which Range would
        # refuse to hold, since expressions do not compare among themselves.
        def between?(min, max)
          In.new(self, In::QuotedRange.new(min, max, false))
        end

        def not_between?(min, max)
          In.new(self, In::QuotedRange.new(min, max, false), negated: true)
        end

        # CASE with this as the operand, compared against each `when`:
        # `:age.when(10).then(1).else(0)`.  The other shape, where each `when`
        # carries its own condition, starts at `case_when`.
        def when(value = nil, &block)
          Case.new(self).when(value, &block)
        end

        def like?(pattern)
          Like.new(self, pattern)
        end

        def not_like?(pattern)
          Like.new(self, pattern, negated: true)
        end

        def ilike?(pattern)
          Like.new(self, pattern, nil, case_sensitive: false)
        end

        def not_ilike?(pattern)
          Like.new(self, pattern, nil, case_sensitive: false, negated: true)
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
          Like.any(self, prefixes.map { |prefix| "#{Like.escape(prefix)}%" })
        end

        def end_with?(*suffixes)
          if suffixes.empty?
            raise ArgumentError, "end_with? needs at least one suffix"
          end
          Like.any(self, suffixes.map { |suffix| "%#{Like.escape(suffix)}" })
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

        # Reading inside a JSON document, by the name of what Hash does.  A
        # string or symbol steps into an object, an integer into an array, and
        # what comes back is still JSON, the way Hash#dig hands back the
        # structure itself -- for a document to be dug into further or asked
        # the JSON questions.  dig_text gives the value as text instead,
        # which is what a comparison wants.
        def dig(*path)
          JsonPath.new(self, path)
        end

        def dig_text(*path)
          JsonPath.new(self, path, json_value: false)
        end

        # Keys taken out of a JSON document, by the name of what Hash does,
        # and taking keys as Hash#except takes them.  Like bury it gives back
        # the document changed rather than writing it anywhere.
        def except(*keys)
          JsonExcept.new(self, keys)
        end

        # What dig reads, bury sets: the last argument is the value and the
        # rest are the path to it.  The document comes back changed rather
        # than being written anywhere, which update_all is for.
        def bury(*path, value)
          JsonSet.new(self, path, value)
        end

        # Whether the document holds what is given, which SQL calls
        # containment.  SQLite has no equivalent.
        def contains?(value)
          JsonContains.new(self, value)
        end

        # Whether the key is there at all, as Hash#key? asks.  Hash has
        # has_key? too; one name is enough, and this is the one Ruby's own
        # style prefers.
        def key?(key)
          JsonHasKey.new(self, key)
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

        # SQL's bitwise operators.  & and | are AND and OR between conditions
        # and are defined there, which is what leaves them free to mean here
        # what SQL means by them.  Ruby's precedence puts all six above the
        # comparisons, so `:flags & 4 > 0` groups the way it reads.
        def &(other)
          Bitwise.new(self, :&, other)
        end

        def |(other)
          Bitwise.new(self, :|, other)
        end

        def ^(other)
          Bitwise.new(self, :^, other)
        end

        def <<(other)
          Bitwise.new(self, :<<, other)
        end

        def >>(other)
          Bitwise.new(self, :>>, other)
        end

        def ~
          BitwiseNot.new(self)
        end
      end

      # Arithmetic with the number on the left, imported into the numeric
      # refinements: 20 - :quantity builds what :quantity + 20 builds.  Only
      # a column or an expression on the right means a query; anything else
      # goes back to the number through super, so 1 + 2 is 3 inside a block
      # too.
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
          Bitwise.new(self, :&, other)
        end

        def |(other)
          return super unless other.is_a?(::Symbol) || other.is_a?(Node)
          Bitwise.new(self, :|, other)
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
      end

      class Node
        # The model travels with the table because some SQL cannot be written
        # without knowing the adapter, and a node is built before anything
        # knows which one it will be rendered for -- a symbol becomes a node
        # inside a refinement, where there is no model to ask.  Most nodes
        # never look at it and only pass it on.
        def to_arel(table, model)
          raise ScriptError, "subclass must override this method"
        end

        def as(alias_name, quote: true)
          As.new(self, alias_name, quote: quote)
        end

        def asc
          Ordering.new(self, :asc)
        end

        def desc
          Ordering.new(self, :desc)
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
      # top of a select list is Active Record's, and a bare string there is SQL
      # rather than a string.  Saying `value` is how you ask for the other
      # meaning, and it carries the predications with it, so a literal can be
      # compared and combined like anything else.
      class Value < Node
        include Predications
        include Arithmetics

        attr_reader :value

        def initialize(value)
          @value = value
        end

        def to_arel(_table, _model)
          Arel::Nodes.build_quoted(value)
        end
      end

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

        attr_reader :operand, :whens, :default

        def initialize(operand = nil, whens = [], default = NOTHING)
          @operand = operand
          @whens = whens
          @default = default
        end

        def when(value = nil, &block)
          Pending.new(self, Case.argument(:when, value, block))
        end

        # Kernel#then is on every object, so `then` in the wrong place would be
        # answered by it -- with no block, silently, with an Enumerator.
        def then(*)
          raise ArgumentError, "then follows a when, and there is none to follow here"
        end

        def else(value = nil, &block)
          Case.new(operand, whens, Case.argument(:else, value, block))
        end

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
        class Pending < Node
          def initialize(kase, condition)
            @kase = kase
            @condition = condition
          end

          def then(value = nil, &block)
            Case.new(@kase.operand,
                     @kase.whens + [[@condition, Case.argument(:then, value, block)]],
                     @kase.default)
          end

          def to_arel(_table, _model)
            raise ArgumentError, "when needs a matching then"
          end
        end
      end

      # A path into a JSON document, spelled the two ways the adapters want it.
      # Shared, because reading a value and setting one walk the same path.
      module JsonSteps
        def check_steps(path, called)
          raise ArgumentError, "#{called} needs a key or an index" if path.empty?
          path.each do |step|
            next if step.is_a?(::Integer) || step.is_a?(::String) || step.is_a?(::Symbol)
            raise ArgumentError, "a step is a key or an array index, not #{step.inspect}"
          end
          path
        end

        # PostgreSQL takes the steps as a text array, where every element is
        # quoted so that a comma or a brace in a key is part of it.  except
        # writes its keys the same way, which are steps of no one path.
        def steps_array(steps = path)
          "{#{steps.map { |step| %("#{escape_step(step)}") }.join(',')}}"
        end

        # MySQL and SQLite take a path expression instead, where an integer is
        # a subscript and a name that is not plain has to be quoted.
        def dollar_path
          path.inject(+"$") { |so_far, step| so_far << dollar_step(step) }
        end

        def dollar_step(step)
          return "[#{step}]" if step.is_a?(::Integer)
          name = step.to_s
          "." + (name.match?(/\A[[:alpha:]_][[:alnum:]_]*\z/) ?
                 name : %("#{escape_step(step)}"))
        end

        def escape_step(step)
          step.to_s.gsub("\\", "\\\\").gsub('"', '\\"')
        end
      end

      # Reading inside a JSON document.  Every adapter can do it and no two
      # spell it alike: PostgreSQL walks an array of steps, SQLite has the
      # operators with a $ path, and MySQL has the functions -- which is what
      # this uses for that family, since MariaDB answers to the same adapter
      # and has no -> at all.
      #
      # The path is turned into a string either way, so a key with a space or
      # a quote in it travels as itself rather than having to be refused.
      # What a dug value may be compared with.  dig_text gives text on every
      # adapter, and what a text value compared with a number means is a
      # question the three answer three ways: `dig_text(:n) == 5` is true on
      # SQLite, an error on PostgreSQL and true on MySQL, while
      # `dig_text(:flag) == true` is true, an error, and false.  cast is what
      # says which type was meant, and then all three agree.
      #
      # dig, bury and except give JSON, and a JSON comparison belongs to the
      # JSON types -- jsonb and MySQL's -- where numbers compare as numbers
      # and documents structurally, key order and spelling aside.  The Ruby
      # value goes in as a JSON literal, and the adapters without such a
      # type refuse it from JsonLiteral when the SQL is written, which is
      # when the adapter is known.
      #
      # A string against dig_text, and anything the block itself built -- a
      # column, a function, another dug value -- go through untouched.
      #
      # Arithmetic and the bit operators are refused outright on both sides:
      # `dig_text(:n) + 1` is 6 on SQLite, an error on PostgreSQL and 6.0 on
      # MariaDB, and an expression on the right does not change what the
      # dug side is.
      module JsonComparable
        %i[== != < <= > >=].each do |operator|
          define_method(operator) do |other|
            super(comparison_value(other))
          end
        end

        def in?(values) = super(comparison_set(values))
        def not_in?(values) = super(comparison_set(values))
        def between?(min, max) = super(comparison_value(min), comparison_value(max))
        def not_between?(min, max) = super(comparison_value(min), comparison_value(max))

        %i[+ - * / & | ^ << >>].each do |operator|
          define_method(operator) do |_other|
            raise ArgumentError, arithmetic_refusal(operator)
          end
        end

        def ~
          raise ArgumentError, arithmetic_refusal(:~)
        end

        private
          # nil is left to the comparison itself, which says to use null?, and
          # so is anything the block built rather than wrote as a literal.
          def comparison_value(other)
            return other if other.nil? || other.is_a?(Node) || other.is_a?(::Symbol) ||
                            other.is_a?(Arel::Nodes::Node) ||
                            other.is_a?(Arel::Attributes::Attribute) ||
                            other.is_a?(ActiveRecord::Relation)
            return json_literal(other) if json_value?
            return other if other.is_a?(::String)

            raise ArgumentError,
              "dig_text gives text, and comparing it with #{other.inspect} means " \
              "something different on every adapter; cast it to the type meant"
          end

          def json_literal(other)
            case other
            when ::String, ::Integer, ::Float, ::BigDecimal, true, false, ::Hash, ::Array
              JsonLiteral.new(other)
            when ::Rational
              raise ArgumentError,
                "a Rational has no exact SQL spelling; to_d says the decimal meant"
            else
              raise ArgumentError,
                "#{json_source} gives JSON, and #{other.inspect} has no JSON " \
                "spelling; dig_text gives the value"
            end
          end

          def comparison_set(values)
            case values
            when ActiveRecord::Relation then values
            when ::Range
              In::QuotedRange.new(comparison_value(values.begin),
                                  comparison_value(values.end), values.exclude_end?)
            else values.map { |value| comparison_value(value) }
            end
          end

          def arithmetic_refusal(operator)
            json_value? ?
              "#{json_source} gives JSON, and #{operator} on it means something " \
              "different on every adapter; cast dig_text to the type meant" :
              "dig_text gives text, and #{operator} on it means something " \
              "different on every adapter; cast it to the type meant"
          end
      end

      # A Ruby value on the JSON side of a comparison, which jsonb and
      # MySQL's JSON type answer alike: numbers compare as numbers and
      # documents structurally.  SQLite and MariaDB have only the text of
      # each -- spelling and key order deciding what equality means -- and
      # refuse here.  PostgreSQL needs no cast, an untyped literal beside a
      # jsonb operand coercing to jsonb; MySQL is told CAST(... AS JSON),
      # since a bare string beside JSON would be a JSON string, and every
      # string outranks every number in its ordering.
      class JsonLiteral < Node
        attr_reader :value

        def initialize(value)
          @value = value
        end

        def to_arel(_table, model)
          json = Arel::Nodes.build_quoted(JSON.generate(value))
          case AST.adapter_family(model)
          when :postgresql then json
          when :mysql then mysql_literal(json, model)
          else refuse(model.connection_db_config.adapter)
          end
        end

        private
          # MariaDB answers to the same adapter and has no JSON type at all.
          def mysql_literal(json, model)
            refuse("MariaDB") if model.with_connection { |c| c.mariadb? }
            Arel::Nodes::NamedFunction.new(
              "CAST", [Arel::Nodes::As.new(json, Arel::Nodes::SqlLiteral.new("JSON"))])
          end

          def refuse(database)
            raise NotImplementedError,
              "a JSON comparison has no equivalent on #{database}; " \
              "dig_text gives the value"
          end
      end

      # The JSON operations read a document, and what dig gives is one:
      # `dig(:author).key?(:email)` and `dig(:tags).contains?(...)` are the
      # same question asked of a part of it, and the adapters answer them
      # alike.  What dig_text gives is text, and reading that as a document
      # again is where they part company: SQLite parses it back and MySQL
      # takes it as written, where PostgreSQL has no such function for text.
      module JsonDocument
        %i[dig dig_text key? contains? bury except].each do |name|
          define_method(name) do |*args|
            unless json_value?
              raise ArgumentError,
                "dig_text gives text, and #{name} reads JSON; dig keeps it"
            end
            super(*args)
          end
        end
      end

      class JsonPath < Node
        include Predications
        include Arithmetics
        include JsonSteps
        include JsonComparable
        include JsonDocument

        attr_reader :operand, :path

        def initialize(operand, path, json_value: true)
          @operand = operand
          @path = check_steps(path, "dig")
          @json_value = json_value
        end

        def json_value?
          @json_value
        end

        def to_arel(table, model)
          document = to_arel_operand(operand, table, model)
          case AST.adapter_family(model)
          when :postgresql
            Arel::Nodes::InfixOperation.new(
              json_value? ? :"#>" : :"#>>", document, Arel::Nodes.build_quoted(steps_array))
          when :mysql
            extracted = Arel::Nodes::NamedFunction.new(
              "JSON_EXTRACT", [document, Arel::Nodes.build_quoted(dollar_path)])
            json_value? ? extracted : Arel::Nodes::NamedFunction.new("JSON_UNQUOTE", [extracted])
          else
            extracted = Arel::Nodes::InfixOperation.new(
              json_value? ? :"->" : :"->>", document, Arel::Nodes.build_quoted(dollar_path))
            # SQLite's ->> gives back the value with its type, where the other
            # two give text.  Cast so that `dig_text(:n) == '5'` means the
            # same thing everywhere, and a number wants a cast everywhere too.
            json_value? ? extracted : Arel::Nodes::NamedFunction.new(
              "CAST", [Arel::Nodes::As.new(extracted, Arel::Nodes::SqlLiteral.new("text"))])
          end
        end

        private
          def json_source
            "dig"
          end
      end

      # Setting a value inside a JSON document, which is what bury does to what
      # dig reads.  The document comes back changed rather than being written
      # anywhere; update_all is what writes it.
      class JsonSet < Node
        include Predications
        include JsonSteps
        include JsonComparable

        attr_reader :operand, :path, :value

        def initialize(operand, path, value)
          @operand = operand
          @path = check_steps(path, "bury")
          @value = value
        end

        # Always JSON, which is what the comparison guard asks.
        def json_value?
          true
        end

        def to_arel(table, model)
          document = to_arel_operand(operand, table, model)
          if AST.adapter_family(model) == :postgresql
            Arel::Nodes::NamedFunction.new(
              "jsonb_set",
              [document, Arel::Nodes.build_quoted(steps_array), postgresql_value(table, model)])
          else
            Arel::Nodes::NamedFunction.new(
              "JSON_SET",
              [document, Arel::Nodes.build_quoted(dollar_path), other_value(table, model)])
          end
        end

        private
          # jsonb_set takes jsonb, so an expression is turned into it and a Ruby
          # value goes in as the JSON that says it -- '"x"' rather than 'x',
          # which is not a document at all.
          def postgresql_value(table, model)
            return Arel::Nodes::NamedFunction.new(
              "to_jsonb", [to_arel_operand(value, table, model)]) if expression?
            Arel::Nodes.build_quoted(JSON.generate(value))
          end

          # The others take the value as it is, except a whole document or a
          # boolean, which go in as JSON: taken as they are, a document would
          # be the string that spells it, and a boolean SQLite's own 1.
          # SQLite's json() marks the literal for JSON_SET; the MySQL family,
          # which has no json(), reads it with JSON_EXTRACT.
          def other_value(table, model)
            return to_arel_operand(value, table, model) if expression?
            unless value.is_a?(::Hash) || value.is_a?(::Array) ||
                   value == true || value == false
              return Arel::Nodes.build_quoted(value)
            end

            json = Arel::Nodes.build_quoted(JSON.generate(value))
            if AST.adapter_family(model) == :sqlite
              Arel::Nodes::NamedFunction.new("json", [json])
            else
              Arel::Nodes::NamedFunction.new(
                "JSON_EXTRACT", [json, Arel::Nodes.build_quoted("$")])
            end
          end

          def expression?
            value.is_a?(Node) || value.is_a?(::Symbol)
          end

          def json_source
            "bury"
          end
      end

      # Keys taken out of a JSON document.  PostgreSQL subtracts them, the
      # other two remove a path apiece.
      class JsonExcept < Node
        include Predications
        include JsonSteps
        include JsonComparable

        attr_reader :operand, :keys

        def initialize(operand, keys)
          @operand = operand
          @keys = check_keys(keys)
        end

        def json_value?
          true
        end

        def to_arel(table, model)
          document = to_arel_operand(operand, table, model)
          if AST.adapter_family(model) == :postgresql
            # Grouped because - binds tighter than #>: dug out of a document,
            # the subtraction would otherwise take the path literal first.
            return Arel::Nodes::InfixOperation.new(
              :-, Arel::Nodes::Grouping.new(document), key_array)
          end

          Arel::Nodes::NamedFunction.new(
            "JSON_REMOVE",
            [document, *keys.map { |key| Arel::Nodes.build_quoted("$#{dollar_step(key)}") }])
        end

        private
          # jsonb has three subtractions -- a key, an array of keys, an element
          # by index -- and an array literal written without a type is read as
          # the first of them: `meta - '{draft}'` takes out the key spelled
          # {draft}, which is nothing, and says nothing about it.
          def key_array
            Arel::Nodes::NamedFunction.new(
              "CAST",
              [Arel::Nodes::As.new(Arel::Nodes.build_quoted(steps_array(keys)),
                                   Arel::Nodes::SqlLiteral.new("text[]"))])
          end

          # Keys, as Hash#except takes them: an index into an array is not what
          # the name says anywhere, and is bury's business through a path.
          def check_keys(keys)
            raise ArgumentError, "except needs a key" if keys.empty?
            keys.each do |key|
              next if key.is_a?(::String) || key.is_a?(::Symbol)
              raise ArgumentError,
                "except takes keys of the document, not #{key.inspect}"
            end
            keys
          end

          def json_source
            "except"
          end
      end

      # JSON containment: whether the document holds what is given.
      class JsonContains < Predicate
        attr_reader :operand, :value

        def initialize(operand, value)
          @operand = operand
          @value = value
        end

        def to_arel(table, model)
          document = to_arel_operand(operand, table, model)
          json = Arel::Nodes.build_quoted(JSON.generate(value))
          case AST.adapter_family(model)
          when :postgresql then Arel::Nodes::Contains.new(document, json)
          when :mysql
            Arel::Nodes::NamedFunction.new("JSON_CONTAINS", [document, json])
          else
            # Later than the others, since the adapter is only known here.
            raise NotImplementedError,
              "contains? has no equivalent on #{model.connection_db_config.adapter}"
          end
        end
      end

      # Whether a key is in the document.  PostgreSQL has an operator for it,
      # ?, which is also what a bind parameter looks like to several drivers;
      # the function it is shorthand for says the same thing and survives.
      class JsonHasKey < Predicate
        attr_reader :operand, :key

        def initialize(operand, key)
          @operand = operand
          @key = key
        end

        def to_arel(table, model)
          document = to_arel_operand(operand, table, model)
          name = Arel::Nodes.build_quoted(key.to_s)
          path = Arel::Nodes.build_quoted("$.#{key}")
          case AST.adapter_family(model)
          when :postgresql
            Arel::Nodes::NamedFunction.new("jsonb_exists", [document, name])
          when :mysql
            Arel::Nodes::NamedFunction.new(
              "JSON_CONTAINS_PATH", [document, Arel::Nodes.build_quoted("one"), path])
          else
            Arel::Nodes::NamedFunction.new("json_type", [document, path]).not_eq(nil)
          end
        end
      end

      # GROUP BY GROUPING SETS / ROLLUP / CUBE: several groupings asked for at
      # once, the totals of each coming back beside the rows.  PostgreSQL has
      # all three and the MySQL family rollup alone; the block raises for the
      # rest before it gets this far.
      #
      # Each set is a list of its own, so grouping_sets takes lists and rollup
      # and cube take the columns themselves.
      class GroupingSets < Node
        KINDS = {
          grouping_sets: Arel::Nodes::GroupingSet,
          rollup: Arel::Nodes::RollUp,
          cube: Arel::Nodes::Cube,
        }.freeze

        attr_reader :kind, :sets

        def initialize(kind, sets)
          raise ArgumentError, "#{kind} needs something to group by" if sets.empty?
          @kind = kind
          @sets = sets
        end

        def to_arel(table, model)
          return with_rollup(table, model) if AST.adapter_family(model) == :mysql

          KINDS.fetch(kind).new(
            if kind == :grouping_sets
              sets.map do |set|
                Arel::Nodes::GroupingElement.new(
                  Array(set).map { |column| to_arel_operand(column, table, model) })
              end
            else
              sets.map { |column| to_arel_operand(column, table, model) }
            end)
        end

        private
          # The MySQL family spells rollup WITH ROLLUP, trailing the whole
          # group list rather than wrapping a list of its own -- which is also
          # why a rollup cannot stand beside other group entries there.  The
          # columns are compiled by the connection's own visitor, so their
          # quoting is the adapter's.
          def with_rollup(table, model)
            columns = sets.map { |column| to_arel_operand(column, table, model) }
            sql = model.with_connection do |connection|
              columns.map { |column| connection.visitor.compile(column) }.join(", ")
            end
            Arel.sql("#{sql} WITH ROLLUP")
          end
      end

      class Column < Node
        include Predications
        include Arithmetics

        attr_reader :table_name, :column_name

        def initialize(table_name, column_name)
          @table_name = table_name
          @column_name = column_name
        end

        def to_arel(_table, _model)
          Arel::Table.new(table_name)[column_name]
        end
      end

      # Arithmetic on columns and expressions.  Ruby's precedence puts these
      # above the comparison operators, so :price * :quantity > 100 groups the
      # way it reads.
      class Arithmetic < Node
        include Predications
        include Arithmetics

        attr_reader :left, :operator, :right

        def initialize(left, operator, right)
          @left = left
          @operator = operator
          @right = right
        end

        def to_arel(table, model)
          arel_left = to_arel_operand(left, table, model)
          # The operator dispatches Arel's Math, which a bare number carries
          # none of; quoted, it is a node with the same methods.
          arel_left = Arel::Nodes.build_quoted(arel_left) if arel_left.is_a?(::Numeric)
          arel_left.public_send(operator, to_arel_operand(right, table, model))
        end
      end

      # What the bitwise operators refuse.  Both refusals are there because
      # the same Ruby would otherwise mean different things per adapter: MySQL
      # and SQLite take a boolean for the one bit it is stored as, so
      # `published & active` would quietly be the AND it looks like, while
      # PostgreSQL has no such operator and would say so.
      module BitwiseOperands
        private
          def check_operand(operand, operator)
            return operand unless operand.is_a?(Predicate)
            raise ArgumentError,
              "a condition cannot be an operand of #{operator}; " \
              "& and | between conditions are AND and OR"
          end

          # Only the unqualified column can be checked, since that is the one
          # the model is known to have.
          def check_not_boolean(operand, operator, model)
            return unless operand.is_a?(::Symbol)
            return unless model.type_for_attribute(operand).type == :boolean
            raise ArgumentError,
              "#{operand.inspect} is a boolean column, which #{operator} does " \
              "not take; #{operand.inspect}.true? is the condition"
          end
      end

      # SQL's bitwise operators.  Each parenthesises itself, which is what
      # keeps Ruby's grouping: PostgreSQL gives & and | the same precedence
      # and reads a | b & c from the left, where Ruby reads the & first.
      class Bitwise < Node
        include Predications
        include Arithmetics
        include BitwiseOperands

        NODES = {
          :& => Arel::Nodes::BitwiseAnd,
          :| => Arel::Nodes::BitwiseOr,
          :<< => Arel::Nodes::BitwiseShiftLeft,
          :>> => Arel::Nodes::BitwiseShiftRight,
        }.freeze

        attr_reader :left, :operator, :right

        def initialize(left, operator, right)
          @left = left
          @operator = operator
          @right = check_operand(right, operator)
        end

        def to_arel(table, model)
          check_not_boolean(left, operator, model)
          check_not_boolean(right, operator, model)
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
            case AST.adapter_family(model)
            when :postgresql then Arel::Nodes::InfixOperation.new("#", left, right)
            when :mysql then Arel::Nodes::BitwiseXor.new(left, right)
            else
              Arel::Nodes::Subtraction.new(
                Arel::Nodes::Grouping.new(Arel::Nodes::BitwiseOr.new(left, right)),
                Arel::Nodes::Grouping.new(Arel::Nodes::BitwiseAnd.new(left, right)))
            end
          end
      end

      # ~, which every adapter has.  MySQL answers with the unsigned 64-bit
      # number where the others answer with a negative one; the bits are the
      # same, and only reading the value back tells them apart.
      class BitwiseNot < Node
        include Predications
        include Arithmetics
        include BitwiseOperands

        attr_reader :operand

        def initialize(operand)
          @operand = check_operand(operand, :~)
        end

        def to_arel(table, model)
          check_not_boolean(operand, :~, model)
          Arel::Nodes::Grouping.new(
            Arel::Nodes::BitwiseNot.new(to_arel_operand(operand, table, model)))
        end
      end

      # OVER, on the two things that can carry a window: an aggregate, and a
      # function.
      module Windowing
        def over
          Over.new(self)
        end
      end

      # A function with a window.  The window is built by chaining, the way
      # Arel's own is, and each method returns a new node rather than adding to
      # this one, so a window can be finished more than one way.
      class Over < Node
        include Predications
        include Arithmetics

        attr_reader :function, :partitions, :orders, :frame

        def initialize(function, partitions = [], orders = [], frame = nil)
          @function = function
          @partitions = partitions
          @orders = orders
          @frame = frame
        end

        def partition(*exprs)
          raise ArgumentError, "partition needs an expression" if exprs.empty?
          Over.new(function, partitions + exprs, orders, frame)
        end

        def order(*exprs)
          raise ArgumentError, "order needs an expression" if exprs.empty?
          Over.new(function, partitions, orders + exprs, frame)
        end

        def rows(bounds)
          Over.new(function, partitions, orders, framing(:rows, bounds))
        end

        def range(bounds)
          Over.new(function, partitions, orders, framing(:range, bounds))
        end

        def to_arel(table, model)
          window = Arel::Nodes::Window.new
          partitions.each { |expr| window.partition(to_arel_operand(expr, table, model)) }
          orders.each { |expr| window.order(to_arel_operand(expr, table, model)) }
          frame_arel(window) if frame

          # The JSON aggregates cannot ride a window everywhere; the node
          # itself says where, once the adapter is known.
          function.check_window(model) if function.is_a?(JsonAggregate)

          # A window-only function refuses to build on its own; here is where
          # it is asked for the call itself.
          arel_function =
            function.is_a?(WindowFunction) ? function.call_arel(table, model)
                                           : function.to_arel(table, model)
          Arel::Nodes::Over.new(arel_function, window)
        end

        private
          # The frame is a range of rows counted from the current one: negative
          # before it, positive after, 0 the row itself, and an open end for
          # unbounded.  `rows(..0)` is what a running total wants.
          def framing(kind, bounds)
            raise ArgumentError, "a window has one frame" if frame
            unless bounds.is_a?(::Range)
              raise ArgumentError, "#{kind} takes a range of rows, as in rows(..0)"
            end
            if bounds.exclude_end?
              raise ArgumentError, "a frame ends on a row rather than before one; use .."
            end
            [bounds.begin, bounds.end].each do |bound|
              next if bound.nil? || bound.is_a?(::Integer)
              raise ArgumentError,
                "a frame bound is a number of rows, or nothing for unbounded"
            end
            [kind, bounds.begin, bounds.end]
          end

          # Arel wants the keyword itself on the left of the BETWEEN, which is
          # what window.rows with no argument hands back.
          def frame_arel(window)
            kind, from, to = frame
            window.frame(
              Arel::Nodes::Between.new(
                window.public_send(kind),
                Arel::Nodes::And.new([bound(from, Arel::Nodes::Preceding.new),
                                      bound(to, Arel::Nodes::Following.new)])))
          end

          def bound(rows, unbounded)
            return unbounded if rows.nil?
            return Arel::Nodes::CurrentRow.new if rows.zero?
            rows.negative? ? Arel::Nodes::Preceding.new(-rows)
                           : Arel::Nodes::Following.new(rows)
          end
      end

      class Aggregate < Node
        include Predications
        include Arithmetics
        include Windowing

        attr_reader :operand, :function, :distinct, :condition

        def initialize(operand, function, distinct: false, condition: nil)
          if distinct && function != :count
            raise ArgumentError, "#{function} does not take distinct"
          end
          if distinct && operand == :*
            raise ArgumentError, "count(:*) does not take distinct; name a column"
          end
          @operand = operand
          @function = function
          @distinct = distinct
          @condition = condition
        end

        # FILTER (WHERE ...): the aggregate is taken over the rows the
        # condition holds for.  A value or a block, as `when` takes them.
        def filter(condition = nil, &block)
          Aggregate.new(operand, function, distinct: distinct,
                        condition: Case.argument(:filter, condition, block))
        end

        def to_arel(table, model)
          return aggregate(operand, table, model) unless condition

          # MySQL has no FILTER clause.  An aggregate passes over a NULL, so
          # the case that yields nothing for the rows the condition misses is
          # the same aggregate over the same rows -- count(*) has no operand to
          # keep, and counts a 1 instead.
          if AST.adapter_family(model) == :mysql
            kept = Case.new.when(condition).then(operand == :* ? 1 : operand)
            return aggregate(kept, table, model)
          end

          aggregate(operand, table, model).filter(condition.to_arel(table, model))
        end

        private
          def aggregate(over, table, model)
            arel_operand = to_arel_operand(over, table, model)
            if function == :count
              arel_operand.count(distinct)
            else
              arel_operand.public_send(function)
            end
          end
      end

      # Rows gathered into one JSON document: json_arrayagg collects a value
      # from each row into an array, json_objectagg a key and a value into an
      # object.  Every adapter has the pair under a name of its own; what
      # PostgreSQL gets is the jsonb one, whose documents the other JSON
      # operations here read.
      class JsonAggregate < Node
        include Predications
        include JsonComparable
        include Windowing

        # The standard names, which are also the DSL's own and MySQL's, serve
        # any adapter the table does not list.
        NAMES = {
          arrayagg: { sqlite: "json_group_array", postgresql: "jsonb_agg" },
          objectagg: { sqlite: "json_group_object",
                       postgresql: "jsonb_object_agg" },
        }.freeze

        attr_reader :kind, :operands, :condition

        def initialize(kind, operands, condition: nil)
          @kind = kind
          @operands = operands
          @condition = condition
        end

        # Always JSON, which is what the comparison guard asks.
        def json_value?
          true
        end

        def filter(condition = nil, &block)
          JsonAggregate.new(kind, operands,
                            condition: Case.argument(:filter, condition, block))
        end

        # MariaDB takes every other aggregate as a window function, but not
        # these two; Over asks here before writing one.
        def check_window(model)
          return unless AST.adapter_family(model) == :mysql
          return unless model.with_connection { |connection| connection.mariadb? }
          raise NotImplementedError,
            "#{json_source} over a window has no equivalent on MariaDB"
        end

        def to_arel(table, model)
          family = AST.adapter_family(model)
          call = Arel::Nodes::NamedFunction.new(
            NAMES.fetch(kind).fetch(family) { "JSON_#{kind.to_s.upcase}" },
            operands.map { |operand| to_arel_argument(operand, table, model) })
          return call unless condition

          # The CASE that stands in for FILTER elsewhere hands the aggregate
          # a NULL for every row the condition misses, and these two keep a
          # NULL -- as JSON null -- rather than passing over it.
          if family == :mysql
            raise NotImplementedError,
              "#{json_source}.filter has no equivalent on " \
              "#{model.connection_db_config.adapter}; a CASE would leave a " \
              "null in the document for every row it drops"
          end
          call.filter(condition.to_arel(table, model))
        end

        private
          def json_source
            "json_#{kind}"
          end

          # JsonComparable's own advice says to reach for dig_text, which an
          # aggregate has no counterpart of.
          def arithmetic_refusal(operator)
            "#{json_source} gives JSON, and #{operator} on it means " \
            "something different on every adapter"
          end
      end

      # A column alias, quoted by the adapter, so that the name asked for is
      # the name that comes back: unquoted, PostgreSQL folds a capital away
      # and the other two keep it, which is one block meaning two things.
      # Quoting also leaves nothing to refuse -- a name that would have been
      # SQL is an identifier with a strange name instead.
      #
      # `quote: false` asks for the name as written, for a schema that wants
      # the folding.
      class As < Node
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

        def to_arel(table, model)
          ordering = to_arel_operand(operand, table, model).public_send(direction)
          nulls ? ordering.public_send(nulls) : ordering
        end
      end

      class Function < Node
        include Predications
        include Arithmetics
        include Windowing

        attr_reader :name, :args

        def initialize(name, args)
          @name = name
          @args = args
        end

        def to_arel(table, model)
          arel_args = args.map { |arg| to_arel_argument(arg, table, model) }
          Arel::Nodes::NamedFunction.new(name, arel_args)
        end
      end

      # ROW_NUMBER and its kind: functions that say nothing without a window.
      # On its own this refuses rather than reaching the database as an error
      # there; over asks it for call_arel instead.
      class WindowFunction < Function
        alias_method :call_arel, :to_arel

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

        attr_reader :field, :operand

        def initialize(field, operand)
          @field = AST.check_name(field, ALIAS_NAME, "extract field")
          @operand = operand
        end

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

        attr_reader :operand, :sql_type

        def initialize(operand, sql_type)
          @operand = operand
          @sql_type = AST.check_name(sql_type, TYPE_NAME, "SQL type")
        end

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

        attr_reader :name, :precision

        def initialize(name, precision = nil)
          unless precision.nil? || precision.is_a?(Integer)
            raise ArgumentError,
              "#{precision.inspect} is not an Integer precision"
          end
          @name = name
          @precision = precision
        end

        def to_arel(_table, _model)
          Arel::Nodes::SqlLiteral.new(
            precision ? "#{name}(#{precision})" : name)
        end
      end

      # A plain SQL comparison. The value is passed through as it is, so a Range
      # or an Array compares against a PostgreSQL range or array column, the way
      # Active Record's own force_equality? types do.
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
        attr_reader :operand, :value, :negated

        def initialize(operand, value, negated: false)
          @operand = operand
          @value = value
          @negated = negated
        end

        def to_arel(table, model)
          literal = value ? Arel::Nodes::True.new : Arel::Nodes::False.new
          Arel::Nodes::InfixOperation.new(negated ? "IS NOT" : "IS",
            to_arel_operand(operand, table, model), literal)
        end
      end

      # A relation standing for a set of values, which is what IN and the
      # quantifiers each take.  The treatment is Active Record's own
      # RelationHandler's: without an explicit select list the subquery
      # selects the model's primary key.
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
        QuotedRange = Struct.new(:begin, :end, :exclude_end) do
          def exclude_end? = exclude_end
        end

        attr_reader :operand, :values, :negated

        def initialize(operand, values, negated: false)
          @operand = operand
          @values = values
          @negated = negated
        end

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
              AST.adapter_family(model) == :mysql
          end

          def json_list?(model)
            values.any? { |value| value.is_a?(JsonLiteral) } &&
              AST.adapter_family(model) == :mysql
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
        def to_arel(_table, _model)
          Arel::Nodes::NamedFunction.new(kind, [set_subquery(relation, kind).ast])
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

        def to_arel(_table, _model)
          subquery = relation
          if subquery.eager_loading?
            subquery = subquery.send(:apply_join_dependency)
          end
          subquery.arel.exists
        end
      end

      class Like < Predicate
        ESCAPE = "\\"

        # Escapes % and _ so that they match literally. The pattern built from
        # the result must be used with ESCAPE, since SQLite has no default
        # escape character.
        def self.escape(string)
          ActiveRecord::Base.sanitize_sql_like(string, ESCAPE)
        end

        # ORs one LIKE per pattern, for the shortcuts that accept several
        # literals the way String#start_with? does.
        def self.any(operand, patterns)
          patterns.map { |pattern| new(operand, pattern, ESCAPE) }.
            inject { |left, right| Or.new(left, right) }
        end

        attr_reader :operand, :pattern, :escape, :case_sensitive, :negated

        def initialize(operand, pattern, escape = nil, case_sensitive: true,
                       negated: false)
          @operand = operand
          @pattern = pattern
          @escape = escape
          @case_sensitive = case_sensitive
          @negated = negated
        end

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
        attr_reader :operand, :value, :negated

        def initialize(operand, value, negated: false)
          @operand = operand
          @value = value
          @negated = negated
        end

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

        def to_arel(table, model)
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
        attr_reader :operand, :pattern, :negated

        def initialize(operand, pattern, negated: false)
          @operand = operand
          @pattern = pattern.is_a?(Regexp) ? regexp_source(pattern) : pattern
          @negated = negated
        end

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

      class And < Predicate
        attr_reader :left, :right

        def initialize(left, right)
          @left = left
          @right = right
        end

        def to_arel(table, model)
          left.to_arel(table, model).and(right.to_arel(table, model))
        end
      end

      class Or < Predicate
        attr_reader :left, :right

        def initialize(left, right)
          @left = left
          @right = right
        end

        def to_arel(table, model)
          left.to_arel(table, model).or(right.to_arel(table, model))
        end
      end

      class Not < Predicate
        attr_reader :operand

        def initialize(operand)
          @operand = operand
        end

        def to_arel(table, model)
          Arel::Nodes::Not.new(operand.to_arel(table, model))
        end
      end
    end
  end
end
