module ActiveRecord
  module Refined
    module BlockSyntax
      refine Symbol do
        import_methods AST::Predications
        import_methods AST::Arithmetics
        import_methods AST::Aggregations

        def as(alias_name)
          AST::As.new(self, alias_name)
        end

        def asc
          AST::Ordering.new(self, :asc)
        end

        def desc
          AST::Ordering.new(self, :desc)
        end

        def [](column_name)
          AST::Column.new(self, column_name)
        end
      end
    end

    class BlockContext
      # The model is only consulted to learn which adapter the query is being
      # built for, which is what decides how a scalar function is spelled.
      def initialize(model)
        @model = model
      end

      AGGREGATE_FUNCTIONS = {
        sum: :sum, avg: :average, min: :minimum, max: :maximum,
      }.freeze

      AGGREGATE_FUNCTIONS.each do |name, arel_func|
        define_method(name) {|column| AST::Aggregate.new(column, arel_func) }
      end

      def count(column, distinct: false)
        AST::Aggregate.new(column, :count, distinct: distinct)
      end

      # Scalar functions, defined as real methods so that a typo is a
      # NoMethodError and a name Kernel also answers to (format, hash, test)
      # cannot quietly mean something else.
      #
      # The value lists the adapters that differ: a string is what the
      # function is called there, nil says the adapter has no equivalent.  An
      # adapter that is not listed spells it like the method.  The families
      # are what the entries key on, so trilogy reads the mysql column.
      #
      # Availability was checked by calling each one; the SQLite figures
      # assume the math functions its build usually enables.
      SCALAR_FUNCTIONS = {
        abs: {}, ceil: {}, coalesce: {}, concat: {}, exp: {}, floor: {},
        length: {}, ln: {}, log: {}, lower: {}, ltrim: {}, mod: {},
        nullif: {}, power: {}, replace: {}, round: {}, rtrim: {}, sqrt: {},
        substr: {}, trim: {}, upper: {},
        char_length: {sqlite: 'LENGTH'},
        greatest: {sqlite: 'MAX'},
        least: {sqlite: 'MIN'},
        now: {sqlite: nil},
        date_trunc: {sqlite: nil, mysql: nil},
        # Named for Kernel#rand, which it also takes back: a block calling
        # rand would otherwise get Ruby's and never reach the database.
        rand: {sqlite: 'RANDOM', postgresql: 'RANDOM'},
        # Two different functions share this name: printf formatting here, and
        # on MySQL the one that puts separators in a number, which reads a
        # printf template as the number zero rather than complaining.  The
        # name keeps the one meaning; fn(:format, ...) reaches MySQL's.
        format: {mysql: nil},
      }.freeze

      ADAPTER_FAMILIES = {
        'sqlite3' => :sqlite,
        'postgresql' => :postgresql,
        'postgis' => :postgresql,
        'mysql2' => :mysql,
        'trilogy' => :mysql,
      }.freeze

      SCALAR_FUNCTIONS.each_key do |name|
        define_method(name) {|*args| AST::Function.new(function_name(name), args) }
      end

      # Escape hatch for functions without a method of their own.  The name is
      # emitted as written, so a case-sensitive one can be spelled exactly,
      # and for that reason it has to be a plain name, optionally qualified by
      # a schema; anything else is refused rather than written into the SQL.
      def fn(name, *args)
        AST::Function.new(
          AST.check_name(name, AST::FUNCTION_NAME, "function name").to_s, args)
      end

      def exists?(relation)
        AST::Exists.new(relation)
      end

      private

      def function_name(name)
        spellings = SCALAR_FUNCTIONS.fetch(name)
        return name.to_s.upcase unless spellings.key?(adapter_family)
        spellings.fetch(adapter_family) ||
          raise(NotImplementedError,
                "#{name} has no equivalent on #{@model.connection_db_config.adapter}")
      end

      # An adapter nobody has classified keeps the standard spellings, and is
      # left to say for itself what it cannot do.
      def adapter_family
        @adapter_family ||=
          ADAPTER_FAMILIES[@model.connection_db_config.adapter] || :unknown
      end
    end

    module QueryMethods
      def where(opts = nil, *rest, &block)
        if block
          super(evaluate_block(&block).to_arel(table))
        else
          super
        end
      end

      def select(*fields, &block)
        if block
          result = evaluate_block(&block)
          arel = Array(result).map {|node| to_arel_field(node) }
          super(*arel, &nil)
        else
          super
        end
      end

      def having(opts = nil, *rest, &block)
        if block
          super(evaluate_block(&block).to_arel(table))
        else
          super
        end
      end

      def order(*args, &block)
        if block
          result = evaluate_block(&block)
          arel = Array(result).map {|node| to_arel_field(node) }
          super(*arel, &nil)
        else
          super
        end
      end

      def group(*args, &block)
        if block
          result = evaluate_block(&block)
          arel = Array(result).map {|node| to_arel_field(node) }
          super(*arel, &nil)
        else
          super
        end
      end

      # A symbol names a table, which ActiveRecord's own from only takes as a
      # string.  With `as` it is selected under another name, which is how a
      # CTE stands in for the model's own table:
      # with_recursive(tree: [...]).from(:tree, as: :nodes)
      def from(value, subquery_name = nil, as: nil)
        unless value.is_a?(Symbol)
          if as
            raise ArgumentError, "as: needs the table named as a symbol"
          end
          return super(value, subquery_name)
        end
        arel_table = Arel::Table.new(value)
        arel_table = arel_table.alias(as) if as
        super(arel_table, subquery_name)
      end

      # `as` names the table within the query, which is what makes a self
      # join expressible: joins(:employees, as: :managers) { ... }.
      def joins(*args, as: nil, &block)
        if block
          super(build_join_node(args.first, Arel::Nodes::InnerJoin, as, &block))
        else
          reject_join_alias(as)
          super(*args, &block)
        end
      end

      def left_outer_joins(*args, as: nil, &block)
        if block
          joins(build_join_node(args.first, Arel::Nodes::OuterJoin, as, &block))
        else
          reject_join_alias(as)
          super(*args, &block)
        end
      end

      private

      def evaluate_block(&block)
        refined_block = block.refined(ActiveRecord::Refined::BlockSyntax)
        BlockContext.new(klass).instance_exec(&refined_block)
      end

      def to_arel_field(node)
        case node
        when AST::Node then node.to_arel(table)
        when Symbol then table[node]
        else node
        end
      end

      def reject_join_alias(alias_name)
        return unless alias_name
        raise ArgumentError, "as: needs a block to write the ON clause with"
      end

      def build_join_node(target_table, join_class, alias_name, &block)
        ast = evaluate_block(&block)
        arel_table = Arel::Table.new(target_table)
        arel_table = arel_table.alias(alias_name) if alias_name
        join_class.new(arel_table, Arel::Nodes::On.new(ast.to_arel(table)))
      end
    end
  end
end
