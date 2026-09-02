# frozen_string_literal: true

# JSON.generate, for the document a containment test is given.
require "json"
require "active_record/refined/ast/node"
require "active_record/refined/ast/windows"

module ActiveRecord
  module Refined
    module AST
      # A path into a JSON document, spelled the two ways the adapters want it.
      # Shared, because reading a value and setting one walk the same path.
      # @private
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

        %i[+ - * / & | ^ << >> bitwise_and bitwise_or bitwise_xor].each do |operator|
          define_method(operator) do |_other|
            raise ArgumentError, arithmetic_refusal(operator)
          end
        end

        def ~
          raise ArgumentError, arithmetic_refusal(:~)
        end

        def bitwise_not
          raise ArgumentError, arithmetic_refusal(:bitwise_not)
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
        # @private
        attr_reader :value

        def initialize(value)
          @value = value
        end

        # @private
        def to_arel(_table, model)
          Dialect.for(model).json_literal(Arel::Nodes.build_quoted(JSON.generate(value)), model)
        end
      end

      # The JSON operations read a document, and what dig gives is one:
      # `dig(:author).key?(:email)` and `dig(:tags).contains?(...)` are the
      # same question asked of a part of it, and the adapters answer them
      # alike.  What dig_text gives is text, and reading that as a document
      # again is where they part company: SQLite parses it back and MySQL
      # takes it as written, where PostgreSQL has no such function for text.
      module JsonDocument
        %i[dig dig_text key? keys contains? bury except].each do |name|
          define_method(name) do |*args|
            unless json_value?
              raise ArgumentError,
                "dig_text gives text, and #{name} reads JSON; dig keeps it"
            end
            super(*args)
          end
        end
      end

      # JSON the query computes rather than reads out of a document: always
      # a JSON value, with no dig_text counterpart for JsonComparable's
      # advice to name.  Included after JsonComparable, whose own
      # arithmetic_refusal it overrides.
      module ComputedJson
        # @private
        def json_value?
          true
        end

        private
          def arithmetic_refusal(operator)
            "#{json_source} gives JSON, and #{operator} on it means " \
            "something different on every adapter"
          end
      end

      # Reading inside a JSON document, which is what {Predications#dig} and
      # {Predications#dig_text} build.  Every adapter can do it and no two
      # spell it alike: PostgreSQL walks an array of steps, SQLite has the
      # operators with a $ path, and MySQL has the functions -- which is what
      # this uses for that family, since MariaDB answers to the same adapter
      # and has no -> at all.
      #
      # The path is turned into a string either way, so a key with a space or
      # a quote in it travels as itself rather than having to be refused.
      # What a dug value compares with is {JsonComparable}'s to say.
      class JsonPath < Node
        include Predications
        include Arithmetics
        include JsonSteps
        include JsonComparable
        include JsonDocument

        # @private
        attr_reader :operand, :path

        def initialize(operand, path, json_value: true)
          @operand = operand
          @path = check_steps(path, "dig")
          @json_value = json_value
        end

        # @private
        def json_value?
          @json_value
        end

        # @private
        def to_arel(table, model)
          Dialect.for(model).json_path(
            to_arel_operand(operand, table, model),
            dollar_path, steps_array, json_value?, model)
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

        # @private
        attr_reader :operand, :path, :value

        def initialize(operand, path, value)
          @operand = operand
          @path = check_steps(path, "bury")
          @value = value
        end

        # Always JSON, which is what the comparison guard asks.
        # @private
        def json_value?
          true
        end

        # @private
        def to_arel(table, model)
          Dialect.for(model).json_set(
            to_arel_operand(operand, table, model),
            steps_array, dollar_path, value,
            (to_arel_operand(value, table, model) if expression?), model)
        end

        private
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

        # @private
        attr_reader :operand, :keys

        def initialize(operand, keys)
          @operand = operand
          @keys = check_keys(keys)
        end

        # @private
        def json_value?
          true
        end

        # @private
        def to_arel(table, model)
          Dialect.for(model).json_remove(
            to_arel_operand(operand, table, model),
            keys.map { |key| "$#{dollar_step(key)}" },
            steps_array(keys), model)
        end

        private
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
        # @private
        attr_reader :operand, :value

        def initialize(operand, value)
          @operand = operand
          @value = value
        end

        # @private
        def to_arel(table, model)
          Dialect.for(model).json_contains(
            to_arel_operand(operand, table, model),
            Arel::Nodes.build_quoted(JSON.generate(value)), model)
        end
      end

      # Whether a key is in the document.  PostgreSQL's spelling is the ?
      # operator rather than jsonb_exists, the function it is shorthand for,
      # because a GIN index matches the operator and never the function.  A
      # ? is a bind placeholder only to sanitize_sql, which none of the SQL
      # written here passes through.
      class JsonHasKey < Predicate
        # @private
        attr_reader :operand, :key

        def initialize(operand, key)
          @operand = operand
          @key = key
        end

        # @private
        def to_arel(table, model)
          Dialect.for(model).json_has_key(
            to_arel_operand(operand, table, model),
            Arel::Nodes.build_quoted(key.to_s),
            Arel::Nodes.build_quoted("$.#{key}"), model)
        end
      end

      # The keys of a JSON document, as Hash#keys gives them: a JSON array.
      # Only the MySQL family has a function for it; the other two reach the
      # same array through a subquery over their key-listing functions.  The
      # type guard is what makes all four answer alike: the keys of what is
      # not an object are NULL rather than SQLite's array indices or
      # PostgreSQL's error, and the keys of {} are [] rather than
      # PostgreSQL's NULL, jsonb_agg over no rows.
      class JsonKeys < Node
        include Predications
        include JsonComparable
        include ComputedJson

        # @private
        attr_reader :operand

        def initialize(operand)
          @operand = operand
        end

        # @private
        def to_arel(table, model)
          Dialect.for(model).json_keys(to_arel_operand(operand, table, model), model)
        end

        private
          def json_source
            "keys"
          end
      end

      # A JSON document built in the row: json_array from the values given,
      # json_object from a Ruby hash.  SQLite and the MySQL family both say
      # the standard names; PostgreSQL is asked to build jsonb, whose
      # documents the other JSON operations here read.
      class JsonBuild < Node
        include Predications
        include JsonComparable
        include ComputedJson

        # @private
        attr_reader :kind, :values

        def initialize(kind, values)
          @kind = kind
          @values = kind == :object ? check_pairs(values) : values
        end

        # @private
        def to_arel(table, model)
          dialect = Dialect.for(model)
          if kind == :array
            dialect.json_build(:array, nil,
              values.map { |value| build_argument(value, dialect, table, model) }, model)
          else
            dialect.json_build(:object, values.keys.map(&:to_s),
              values.values.map { |value| build_argument(value, dialect, table, model) }, model)
          end
        end

        private
          # An expression is itself and a bare scalar is quoted; a document or
          # a boolean the dialect embeds as JSON, as bury takes it.
          def build_argument(value, dialect, table, model)
            case value
            when Node, ::Symbol then to_arel_operand(value, table, model)
            when ::Hash, ::Array, true, false then dialect.json_build_argument(value, model)
            when ::Rational then quote_number(value)
            else Arel::Nodes.build_quoted(value)
            end
          end

          # The keys come from Ruby as Hash keys rather than alternating with
          # the values as SQL has them, which is what keeps a bare symbol
          # free to mean a column on the value side.  Anything but a name is
          # refused here, before the adapters answer a NULL key three ways.
          def check_pairs(pairs)
            unless pairs.is_a?(::Hash)
              raise ArgumentError,
                "json_object takes a hash of keys to values, not #{pairs.inspect}"
            end
            pairs.each_key do |key|
              next if key.is_a?(::String) || key.is_a?(::Symbol)
              raise ArgumentError,
                "a key of json_object is a string or a symbol, not #{key.inspect}"
            end
            pairs
          end

          def json_source
            "json_#{kind}"
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
        include ComputedJson
        include Windowing

        # @private
        attr_reader :kind, :operands, :condition

        def initialize(kind, operands, condition: nil)
          @kind = kind
          @operands = operands
          @condition = condition
        end

        # `FILTER (WHERE condition)`, as {Aggregate#filter}; refused on the
        # MySQL family, where the CASE that stands in would leave a JSON null
        # for every row it drops.
        # @return [AST::JsonAggregate]
        def filter(condition = nil, &block)
          JsonAggregate.new(kind, operands,
                            condition: Case.argument(:filter, condition, block))
        end

        # Over asks here before writing a window, since a family may take
        # every other aggregate as one but not these two.
        # @private
        def check_window(model)
          Dialect.for(model).check_json_aggregate_window(json_source, model)
        end

        # @private
        def to_arel(table, model)
          dialect = Dialect.for(model)
          call = Arel::Nodes::NamedFunction.new(
            dialect.json_aggregate_name(kind),
            operands.map { |operand| to_arel_argument(operand, table, model) })
          return call unless condition

          # The CASE that stands in for FILTER elsewhere hands the aggregate a
          # NULL for every row the condition misses, and these two keep a NULL
          # -- as JSON null -- rather than passing over it, so it is refused.
          unless dialect.json_aggregate_filter_supported?
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
      end
    end
  end
end
