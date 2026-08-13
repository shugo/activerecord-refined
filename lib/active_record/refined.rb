module ActiveRecord
  module Refined
    module BlockSyntax
      refine Symbol do
        import_methods AST::Predications
        import_methods AST::Arithmetics
        import_methods AST::Aggregations

        def as(alias_name, quote: true)
          AST::As.new(self, alias_name, quote: quote)
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

      # Shorthand for `value(0).as(:depth)` and the like.  Numbers only: a
      # string in a select list already means SQL rather than a string, so
      # giving String this would make the same literal mean two things
      # depending on whether it had been sent a message.
      [Integer, Float].each do |klass|
        refine klass do
          def as(alias_name, quote: true)
            AST::As.new(AST::Value.new(self), alias_name, quote: quote)
          end
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
        abs: {}, acos: {}, asin: {}, atan: {}, atan2: {}, ceil: {},
        coalesce: {}, concat: {}, cos: {}, degrees: {}, exp: {}, floor: {},
        length: {}, ln: {}, log: {}, log10: {}, lower: {}, ltrim: {},
        mod: {}, nullif: {}, pi: {}, power: {}, radians: {}, replace: {},
        round: {}, rtrim: {}, sign: {}, sin: {}, sqrt: {}, substr: {},
        tan: {}, trim: {}, upper: {},
        char_length: {sqlite: 'LENGTH'},
        greatest: {sqlite: 'MAX'},
        least: {sqlite: 'MIN'},
        # PostgreSQL spells log2(x) as log(2, x), which no renaming carries.
        log2: {postgresql: nil},
        # MySQL's TRUNCATE insists on the second argument, where the others
        # default it to zero; SQLite's trunc takes only the one.
        trunc: {mysql: 'TRUNCATE'},
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

      SCALAR_FUNCTIONS.each_key do |name|
        define_method(name) do |*args|
          AST::Function.new(function_name(name, SCALAR_FUNCTIONS), args)
        end
      end

      # The datetime value functions, as the SQL grammar calls them.  These
      # the grammar has bare -- PostgreSQL and SQLite reject them written with
      # parentheses -- and the one thing that does go into parentheses is an
      # optional precision, current_timestamp(3), which current_date never
      # takes and SQLite never accepts.  The table reads like
      # SCALAR_FUNCTIONS; current_timestamp is the portable spelling of what
      # now means, reaching SQLite where now does not.
      DATETIME_VALUE_FUNCTIONS = {
        current_date: {},
        current_time: {},
        current_timestamp: {},
        localtime: {sqlite: nil},
        localtimestamp: {sqlite: nil},
      }.freeze

      def current_date
        AST::DatetimeValueFunction.new(
          function_name(:current_date, DATETIME_VALUE_FUNCTIONS))
      end

      (DATETIME_VALUE_FUNCTIONS.keys - [:current_date]).each do |name|
        define_method(name) do |precision = nil|
          # Built first so that a precision of the wrong type is an
          # ArgumentError on every adapter, before SQLite gets to say it takes
          # none at all.
          node = AST::DatetimeValueFunction.new(
            function_name(name, DATETIME_VALUE_FUNCTIONS), precision)
          if precision && adapter_family == :sqlite
            raise NotImplementedError,
              "#{name} takes no precision on #{@model.connection_db_config.adapter}"
          end
          node
        end
      end

      # EXTRACT(field FROM expr).  The field is a keyword, not a value, so it
      # has to be a plain name; the node checks it.  SQLite spells all of
      # this as strftime formats, which no renaming carries, so it raises
      # there -- after the node is built, so that a bad field is an
      # ArgumentError on every adapter.
      def extract(field, expr)
        node = AST::Extract.new(field, expr)
        if adapter_family == :sqlite
          raise NotImplementedError,
            "extract has no equivalent on #{@model.connection_db_config.adapter}"
        end
        node
      end

      # CAST(expr AS type).  The type is the adapter's own name for it,
      # checked for shape by the node; whether it exists is the database's to
      # say.
      def cast(expr, type)
        AST::Cast.new(expr, type)
      end

      # The functions that only mean anything with a window.  Every adapter
      # that has window functions at all spells these the same -- PostgreSQL,
      # MySQL 8, SQLite 3.25 -- so unlike the scalar functions there is nothing
      # here to translate.  Each says so if `over` never arrives.
      %i[row_number rank dense_rank percent_rank cume_dist].each do |name|
        define_method(name) { AST::WindowFunction.new(name.to_s.upcase, []) }
      end

      %i[ntile first_value last_value].each do |name|
        define_method(name) {|arg| AST::WindowFunction.new(name.to_s.upcase, [arg]) }
      end

      def nth_value(expr, nth)
        AST::WindowFunction.new('NTH_VALUE', [expr, nth])
      end

      # The offset is written out rather than left to default, so that a
      # default value cannot end up where the offset belongs.
      def lag(expr, offset = 1, default = nil)
        AST::WindowFunction.new('LAG', default.nil? ? [expr, offset] : [expr, offset, default])
      end

      def lead(expr, offset = 1, default = nil)
        AST::WindowFunction.new('LEAD', default.nil? ? [expr, offset] : [expr, offset, default])
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

      # A literal where an expression is expected, quoted like any other value:
      #
      #   select { [:id, value(0).as(:depth)] }
      #
      # Needed because the top of a select list is ActiveRecord's, and a bare
      # string there is SQL rather than a string.  Numbers have a shorthand --
      # `0.as(:depth)` -- since nothing else could be meant by one.
      def value(literal)
        AST::Value.new(literal)
      end

      # The row an upsert could not insert, for the block upsert_all takes.
      # PostgreSQL and SQLite give it a name; MySQL spells the same thing
      # VALUES(column), which takes the column bare.
      def excluded(column)
        return AST::Column.new(:excluded, column) unless adapter_family == :mysql

        quoted = @model.with_connection {|c| c.quote_column_name(column) }
        AST::Function.new('VALUES', [Arel::Nodes::SqlLiteral.new(quoted)])
      end

      # CASE.  `case` is a keyword, so Ruby only reaches this one through the
      # receiver -- `self.case` -- which is why the two shapes have shorthands
      # that do not need it: `:age.when(...)` for the form with an operand, and
      # `case_when` for the form where each when carries its own condition.
      #
      #   self.case(:age).when(10).then(1).else(0)
      #   self.case.when { :age >= 60 }.then { :age - 60 }
      def case(operand = nil)
        AST::Case.new(operand)
      end

      # The searched CASE, started at its first when:
      #
      #   case_when { :age >= 60 }.then { :age - 60 }.else(0)
      def case_when(value = nil, &block)
        AST::Case.new.when(value, &block)
      end

      private

      def function_name(name, functions)
        spellings = functions.fetch(name)
        return name.to_s.upcase unless spellings.key?(adapter_family)
        spellings.fetch(adapter_family) ||
          raise(NotImplementedError,
                "#{name} has no equivalent on #{@model.connection_db_config.adapter}")
      end

      def adapter_family
        @adapter_family ||= AST.adapter_family(@model)
      end
    end

    module QueryMethods
      def where(opts = nil, *rest, &block)
        if block
          super(evaluate_block(&block).to_arel(table, klass))
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
          super(evaluate_block(&block).to_arel(table, klass))
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
      # string.  With `as` it is selected under another name; when that name
      # is the model's own, from_cte says the same thing without repeating it.
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

      # Selects a CTE in place of the model's own table.  The alias is not a
      # choice -- ActiveRecord keeps qualifying columns with the table name,
      # so the model's is the only name that works -- which is why it is
      # taken from the model rather than asked for:
      # with_recursive(tree: [...]).from_cte(:tree)
      #
      # The name is checked against what `with` declares, so that a typo is
      # not a query against a table nobody has.  Checked when the SQL is
      # built, since the CTE may be declared after this in the chain, or by a
      # scope merged into it.
      def from_cte(name)
        unless name.is_a?(Symbol)
          raise ArgumentError, "from_cte takes the CTE's name as a symbol"
        end
        relation = from(name, as: klass.table_name)
        relation.from_cte_value = name
        relation
      end

      def from_cte_value
        @values[:from_cte]
      end

      def from_cte_value=(name)
        assert_modifiable!
        @values[:from_cte] = name
      end

      # DISTINCT ON (...), which keeps the first row of each group the order
      # brings up.  PostgreSQL has it and the others do not; Arel carries the
      # node and refuses to write it elsewhere, the way it does a regexp, so
      # there is nothing for this to check:
      #
      #   Post.distinct_on { :author }.order { [:author, :likes.desc] }
      #
      # The portable shape is a row_number window in a subquery, which the
      # README shows.
      def distinct_on(*columns, &block)
        spawn.distinct_on!(*columns, &block)
      end

      def distinct_on!(*columns, &block)
        columns = Array(evaluate_block(&block)) if block
        if columns.empty?
          raise ArgumentError, "distinct_on needs a column or an expression"
        end
        self.distinct_on_values += columns
        self
      end

      # ActiveRecord generates these for the values it knows about; this one
      # is ours, and lives in the same place so that it survives a spawn.
      def distinct_on_values
        @values.fetch(:distinct_on, ActiveRecord::QueryMethods::FROZEN_EMPTY_ARRAY)
      end

      def distinct_on_values=(columns)
        assert_modifiable!
        @values[:distinct_on] = columns
      end

      # `as` names the table within the query, which is what makes a self
      # join expressible: joins(:employees, as: :managers) { ... }.
      #
      # `lateral` joins a relation instead of a table, and lets it see the row
      # being joined to -- the top few rows of each group, and the like.
      def joins(*args, as: nil, lateral: false, &block)
        if lateral
          super(build_lateral_join(args.first, Arel::Nodes::InnerJoin, as, &block))
        elsif block
          super(build_join_node(args.first, Arel::Nodes::InnerJoin, as, &block))
        else
          reject_join_alias(as)
          super(*args, &block)
        end
      end

      def left_outer_joins(*args, as: nil, lateral: false, &block)
        if lateral
          joins(build_lateral_join(args.first, Arel::Nodes::OuterJoin, as, &block))
        elsif block
          joins(build_join_node(args.first, Arel::Nodes::OuterJoin, as, &block))
        else
          reject_join_alias(as)
          super(*args, &block)
        end
      end

      private

      def build_arel(...)
        check_from_cte
        arel = super
        unless distinct_on_values.empty?
          arel.distinct_on(distinct_on_values.map {|column| to_arel_field(column) })
        end
        arel
      end

      # Only when every `with` is one this can read the names out of; anything
      # else and there is nothing to be sure about, so nothing is said.
      def check_from_cte
        name = from_cte_value
        return unless name
        return unless with_values.all? {|value| value.is_a?(::Hash) }

        declared = with_values.flat_map {|value| value.keys.map(&:to_sym) }
        return if declared.include?(name)

        raise ArgumentError,
          "from_cte(#{name.inspect}) names no CTE; " +
          (declared.empty? ? "this query declares none" :
                             "this query declares #{declared.map(&:inspect).join(', ')}")
      end

      def evaluate_block(&block)
        refined_block = block.refined(ActiveRecord::Refined::BlockSyntax)
        BlockContext.new(klass).instance_exec(&refined_block)
      end

      def to_arel_field(node)
        case node
        when AST::Node then node.to_arel(table, klass)
        when Symbol then table[node]
        else node
        end
      end

      def reject_join_alias(alias_name)
        return unless alias_name
        raise ArgumentError, "as: needs a block to write the ON clause with"
      end

      # The subquery is written out rather than handed over as a tree: Arel has
      # a LATERAL node but only PostgreSQL's visitor writes it, and MySQL can
      # read what it will not write.  Without a block the join is ON TRUE,
      # which is the usual shape -- what the subquery is allowed to see is
      # what makes it lateral, and that is said inside it.
      def build_lateral_join(relation, join_class, alias_name, &block)
        unless relation.is_a?(ActiveRecord::Relation)
          raise ArgumentError, "a lateral join takes a relation to join against"
        end
        unless alias_name
          raise ArgumentError, "a lateral join needs a name: joins(..., as: :top)"
        end
        check_lateral_support

        aliased = Arel::Nodes::TableAlias.new(
          Arel::Nodes::SqlLiteral.new("LATERAL (#{relation.to_sql})"), alias_name)
        on = block ? evaluate_block(&block).to_arel(table, klass) : Arel::Nodes::True.new
        join_class.new(aliased, Arel::Nodes::On.new(on))
      end

      # PostgreSQL has LATERAL and so does MySQL, from 8.0.14.  SQLite has
      # none, and neither has MariaDB, which answers to the same adapter as
      # MySQL.  An adapter nobody has classified is left to say for itself.
      def check_lateral_support
        case AST.adapter_family(klass)
        when :sqlite
          refuse_lateral('sqlite3')
        when :mysql
          refuse_lateral('MariaDB') if klass.with_connection {|c| c.mariadb? }
        end
      end

      def refuse_lateral(database)
        raise NotImplementedError, "a lateral join has no equivalent on #{database}"
      end

      def build_join_node(target_table, join_class, alias_name, &block)
        ast = evaluate_block(&block)
        arel_table = Arel::Table.new(target_table)
        arel_table = arel_table.alias(alias_name) if alias_name
        join_class.new(arel_table, Arel::Nodes::On.new(ast.to_arel(table, klass)))
      end
    end

    # The writing statements, which live on Relation rather than in
    # QueryMethods.  What a block adds here is the one thing their arguments
    # cannot carry: a value worked out from the row rather than given.
    module Writes
      # `update_all(likes: :likes)` sets the column to the symbol; the block
      # reads a symbol as the column it names, as every other block here does,
      # which is what lets the new value be built from the old:
      #
      #   Post.where { ... }.update_all { { likes: :likes + 1 } }
      def update_all(updates = nil, &block)
        return super(updates) unless block
        if updates
          raise ArgumentError, "update_all takes updates or a block, not both"
        end
        result = evaluate_block(&block)
        unless result.is_a?(::Hash)
          raise ArgumentError, "the block gives update_all a hash of column => value"
        end
        super(result.transform_values {|value| to_arel_field(value) })
      end

      # upsert_all's on_duplicate takes SQL text and nothing else, so this is
      # the one place the DSL writes the SQL out itself rather than handing
      # Arel a tree.  `excluded` is the row that could not be inserted:
      #
      #   Post.upsert_all(rows, unique_by: :title) {
      #     { likes: :likes + excluded(:likes) }
      #   }
      def upsert_all(attributes, **options, &block)
        return super(attributes, **options) unless block
        if options.key?(:on_duplicate)
          raise ArgumentError, "upsert_all takes on_duplicate: or a block, not both"
        end
        result = evaluate_block(&block)
        unless result.is_a?(::Hash)
          raise ArgumentError, "the block gives upsert_all a hash of column => value"
        end
        if result.empty?
          raise ArgumentError, "the block gives upsert_all at least one column to set"
        end
        super(attributes, on_duplicate: Arel.sql(set_clause(result)), **options)
      end

      private

      # The left of each assignment is the column being written, which is bare
      # -- the statement is already about one table -- and the right is the
      # expression, compiled here because a string is what on_duplicate reads.
      def set_clause(updates)
        klass.with_connection do |connection|
          updates.map do |column, value|
            expression = connection.visitor.compile(
              to_arel_field(value), Arel::Collectors::SQLString.new)
            "#{connection.quote_column_name(column)}=#{expression}"
          end.join(', ')
        end
      end
    end
  end
end
