# frozen_string_literal: true

module ActiveRecord
  module Refined
    module BlockSyntax
      refine Symbol do
        import_methods AST::Predications
        import_methods AST::Arithmetics

        def as(alias_name, quote: true)
          AST::As.new(self, alias_name, quote: quote)
        end

        def asc
          AST::Ordering.new(self, :asc)
        end

        def desc
          AST::Ordering.new(self, :desc)
        end

        def collate(name)
          AST::Collate.new(self, name)
        end

        def [](column_name)
          AST::Column.new(self, column_name)
        end
      end

      # Shorthand for `value(0).as(:depth)` and the like, and arithmetic with
      # the number on the left: 20 - :quantity.  BigDecimal is a number here
      # because that is what a decimal column's values are.
      [Integer, Float, BigDecimal].each do |klass|
        refine klass do
          import_methods AST::NumericArithmetics

          def as(alias_name, quote: true)
            AST::As.new(AST::Value.new(self), alias_name, quote: quote)
          end
        end
      end

      # A string is a value here as it is in every other position of a block;
      # SQL is asked for by name, with sql().
      refine String do
        def as(alias_name, quote: true)
          AST::As.new(AST::Value.new(self), alias_name, quote: quote)
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
        define_method(name) { |column| AST::Aggregate.new(column, arel_func) }
      end

      def count(column, distinct: false)
        AST::Aggregate.new(column, :count, distinct: distinct)
      end

      # Rows gathered into one JSON document: json_arrayagg collects a value
      # from each row into an array, json_objectagg a key and a value into an
      # object.
      def json_arrayagg(value)
        AST::JsonAggregate.new(:arrayagg, [value])
      end

      def json_objectagg(key, value)
        AST::JsonAggregate.new(:objectagg, [key, value])
      end

      # A JSON document built in the row: json_array from the values given,
      # json_object from a Ruby hash whose values are expressions.
      def json_array(*values)
        AST::JsonBuild.new(:array, values)
      end

      def json_object(pairs = {})
        AST::JsonBuild.new(:object, pairs)
      end

      # Scalar functions, defined as real methods so that a typo is a
      # NoMethodError and a name Kernel also answers to (format, hash, test)
      # cannot quietly mean something else.  Where one is spelled other than as
      # its plain upper-cased name, and where a family has no equivalent, is
      # the dialect's to say; here is only the list of them.
      SCALAR_FUNCTIONS = %i[
        abs acos asin atan atan2 ceil coalesce concat cos exp floor length ln
        log lower ltrim mod nullif power replace round rtrim sign sin sqrt
        substr tan trim upper degrees radians pi char_length greatest least
        log2 log10 trunc now bit_and bit_or bit_xor date_trunc rand format
      ].freeze

      SCALAR_FUNCTIONS.each do |name|
        define_method(name) do |*args|
          AST::Function.new(dialect.function_name(name, @model), args)
        end
      end

      # The datetime value functions, as the SQL grammar calls them.  These
      # the grammar has bare -- PostgreSQL and SQLite reject them written with
      # parentheses -- and the one thing that does go into parentheses is an
      # optional precision, current_timestamp(3), which current_date never
      # takes and SQLite never accepts.  The table reads like
      # SCALAR_FUNCTIONS; current_timestamp is the portable spelling of what
      # now means, reaching SQLite where now does not.
      DATETIME_VALUE_FUNCTIONS = %i[
        current_date current_time current_timestamp localtime localtimestamp
      ].freeze

      def current_date
        AST::DatetimeValueFunction.new(dialect.function_name(:current_date, @model))
      end

      (DATETIME_VALUE_FUNCTIONS - [:current_date]).each do |name|
        define_method(name) do |precision = nil|
          # Built first so that a precision of the wrong type is an
          # ArgumentError on every adapter, before SQLite gets to say it takes
          # none at all.
          node = AST::DatetimeValueFunction.new(
            dialect.function_name(name, @model), precision)
          if precision && !dialect.datetime_precision_supported?
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
        unless dialect.extract_supported?
          raise NotImplementedError,
            "extract has no equivalent on #{@model.connection_db_config.adapter}"
        end
        node
      end

      # GROUP BY GROUPING SETS / ROLLUP / CUBE.  PostgreSQL has all three;
      # the MySQL family has WITH ROLLUP, which says rollup and only rollup,
      # trailing the group list -- the node spells it there.  Arel has the
      # nodes and writes them for PostgreSQL alone, so what it would raise
      # elsewhere says nothing; this says it here, as extract does, while
      # the block is being read.
      #
      #   Sale.group { grouping_sets([:region], [:product], []) }
      #   Sale.group { rollup(:region, :product) }
      def grouping_sets(*sets)
        grouping(:grouping_sets, sets)
      end

      def rollup(*columns)
        grouping(:rollup, columns)
      end

      def cube(*columns)
        grouping(:cube, columns)
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
        define_method(name) { |arg| AST::WindowFunction.new(name.to_s.upcase, [arg]) }
      end

      def nth_value(expr, nth)
        AST::WindowFunction.new("NTH_VALUE", [expr, nth])
      end

      # The offset is written out rather than left to default, so that a
      # default value cannot end up where the offset belongs.
      def lag(expr, offset = 1, default = nil)
        AST::WindowFunction.new("LAG", default.nil? ? [expr, offset] : [expr, offset, default])
      end

      def lead(expr, offset = 1, default = nil)
        AST::WindowFunction.new("LEAD", default.nil? ? [expr, offset] : [expr, offset, default])
      end

      # Escape hatch for functions without a method of their own.  The name is
      # emitted as written, so a case-sensitive one can be spelled exactly,
      # and for that reason it has to be a plain name, optionally qualified by
      # a schema; anything else is refused rather than written into the SQL.
      def fn(name, *args)
        AST::Function.new(
          AST.check_name(name, AST::FUNCTION_NAME, "function name").to_s, args)
      end

      # The same escape hatch for operators: op("&&", :tags, "{ruby,sql}").
      def op(operator, left, right)
        AST::Operation.new(operator, left, right)
      end

      # BIT_COUNT.  MySQL counts the bits of a number; PostgreSQL counts those
      # of a bit string, so the argument is cast, and to bit(64) because that
      # is what makes a negative come back as MySQL has it -- 64 bits of two's
      # complement rather than as many as the column happens to be wide.
      def bit_count(expr)
        dialect.bit_count(expr, @model)
      end

      def exists?(relation)
        AST::Exists.new(relation)
      end

      # ANY and ALL quantify a comparison over a subquery, which is what a
      # scalar subquery cannot do: it has to return the one row.
      #
      #   Post.where { :likes > any(Post.published.select(:likes)) }
      #   Post.where { :likes >= all(Post.select(:likes)) }
      #
      # `== any` is IN and `!= all` is NOT IN, so what these add is the four
      # comparisons IN has no spelling for.
      def any(relation)
        quantified("ANY", relation)
      end

      def all(relation)
        quantified("ALL", relation)
      end

      # SQL as written, asked for by name:
      #
      #   where { sql("length(name) > ?", 10) }
      #
      # The one way a string means SQL inside a block.  ? and :name
      # placeholders take quoted values, through sanitize_sql_array.
      def sql(statement, *binds)
        AST::Sql.new(statement, binds)
      end

      # A literal where an expression is expected, quoted like any other value:
      #
      #   select { [:id, value(0).as(:depth)] }
      #
      # Numbers and strings have a shorthand -- `0.as(:depth)` -- so this is
      # the spelling for the rest: true, nil, a date.
      def value(literal)
        AST::Value.new(literal)
      end

      # The row an upsert could not insert, for the block upsert_all takes.
      # PostgreSQL and SQLite give it a name; MySQL spells the same thing
      # VALUES(column), which takes the column bare.
      def excluded(column)
        dialect.excluded(column, @model)
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
        # SQLite is the one adapter with no quantifier at all, and what it says
        # when it meets one is a syntax error at the SELECT.
        def quantified(kind, relation)
          unless dialect.quantifiers_supported?
            raise NotImplementedError,
              "#{kind} has no equivalent on #{@model.connection_db_config.adapter}"
          end
          AST::Quantified.new(kind, relation)
        end

        def grouping(kind, sets)
          node = AST::GroupingSets.new(kind, sets)
          return node if dialect.grouping_supported?(kind)

          raise NotImplementedError,
            "#{kind} has no equivalent on #{@model.connection_db_config.adapter}"
        end

        def dialect
          @dialect ||= Dialect.for(@model)
        end
    end

    module QueryMethods
      def where(opts = nil, *rest, &block)
        if block
          super(to_arel_condition(evaluate_block(&block)))
        else
          super
        end
      end

      def select(*fields, &block)
        if block
          super(*to_arel_fields(evaluate_block(&block)), &nil)
        else
          super
        end
      end

      def having(opts = nil, *rest, &block)
        if block
          super(to_arel_condition(evaluate_block(&block)))
        else
          super
        end
      end

      def order(*args, &block)
        if block
          super(*to_arel_fields(evaluate_block(&block)), &nil)
        else
          super
        end
      end

      def group(*args, &block)
        if block
          result = evaluate_block(&block)
          check_rollup_stands_alone(result)
          super(*to_arel_fields(result), &nil)
        else
          super
        end
      end

      # A symbol names a table, which Active Record's own from only takes as a
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
      # choice -- Active Record keeps qualifying columns with the table name,
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

      # Active Record generates these for the values it knows about; this one
      # is ours, and lives in the same place so that it survives a spawn.
      def distinct_on_values
        @values.fetch(:distinct_on, ActiveRecord::QueryMethods::FROZEN_EMPTY_ARRAY)
      end

      def distinct_on_values=(columns)
        assert_modifiable!
        @values[:distinct_on] = columns
      end

      # Marks the relation for a lateral join, which lets it see the row being
      # joined to -- the top few rows of each group, and the like.  In SQL the
      # keyword modifies the subquery, not the join, so it is said on the
      # relation: left_outer_joins(top_post.lateral, as: :top).
      def lateral
        spawn.lateral!
      end

      def lateral!
        self.lateral_value = true
        self
      end

      def lateral_value
        @values[:lateral]
      end

      def lateral_value=(value)
        assert_modifiable!
        @values[:lateral] = value
      end

      # `as` names the table within the query, which is what makes a self
      # join expressible: joins(:employees, as: :managers) { ... }.
      def joins(*args, as: nil, &block)
        if args.first.is_a?(ActiveRecord::Relation)
          super(build_lateral_join(args.first, Arel::Nodes::InnerJoin, as, &block))
        elsif block
          super(build_join_node(args.first, Arel::Nodes::InnerJoin, as, &block))
        else
          reject_join_alias(as)
          super(*args, &block)
        end
      end

      def left_outer_joins(*args, as: nil, &block)
        if args.first.is_a?(ActiveRecord::Relation)
          joins(build_lateral_join(args.first, Arel::Nodes::OuterJoin, as, &block))
        elsif block
          joins(build_join_node(args.first, Arel::Nodes::OuterJoin, as, &block))
        else
          reject_join_alias(as)
          super(*args, &block)
        end
      end

      # The other two outer joins, which Active Record has no method for and
      # Arel has the nodes for.  The rules are joins': the block is the ON,
      # `as` names the table within the query, a relation marked `lateral`
      # joins as one.  An association name is not among them -- what Active
      # Record reads out of one is an inner or a left join and nothing else.
      def right_outer_joins(*args, as: nil, &block)
        outer_joins(:right_outer_joins, Arel::Nodes::RightOuterJoin,
                    args, as, &block)
      end

      def full_outer_joins(*args, as: nil, &block)
        check_full_outer_support
        outer_joins(:full_outer_joins, Arel::Nodes::FullOuterJoin,
                    args, as, &block)
      end

      # CROSS JOIN: every row of one table against every row of the other, so
      # unlike the joins above there is no condition to give and no block to
      # write it in.
      #
      #   Post.cross_joins(:authors)
      #   Post.cross_joins(:posts, as: :others)
      def cross_joins(*args, as: nil, &block)
        if block
          raise ArgumentError,
            "a cross join has no condition; joins is the one that takes a block"
        end
        joins(build_cross_join(args.first, as))
      end

      private
        def build_arel(...)
          check_from_cte
          arel = super
          unless distinct_on_values.empty?
            arel.distinct_on(distinct_on_values.map { |column| to_arel_field(column) })
          end
          arel
        end

        # Only when every `with` is one this can read the names out of; anything
        # else and there is nothing to be sure about, so nothing is said.
        def check_from_cte
          name = from_cte_value
          return unless name
          return unless with_values.all? { |value| value.is_a?(::Hash) }

          declared = with_values.flat_map { |value| value.keys.map(&:to_sym) }
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

        # WITH ROLLUP trails the whole group list, so on the MySQL family a
        # rollup cannot stand beside other group entries the way PostgreSQL's
        # ROLLUP(...) can.
        def check_rollup_stands_alone(result)
          entries = Array(result)
          return if entries.size == 1
          return unless entries.any? { |node| node.is_a?(AST::GroupingSets) }
          return unless Dialect.for(klass).grouping_by_with_rollup?

          raise ArgumentError,
            "WITH ROLLUP takes the whole group list; group by the rollup alone"
        end

        def to_arel_condition(result)
          return result if result.is_a?(Arel::Nodes::SqlLiteral)
          if result.is_a?(::String)
            raise ArgumentError,
              "#{result.inspect} is a string, not a condition; sql(...) " \
              "writes one as SQL"
          end
          result.to_arel(table, klass)
        end

        # The top of a select, order or group list.  A bare string is refused
        # rather than passed to Active Record, where it would be SQL: inside a
        # block a string is a value in every other position, and a literal
        # whose meaning turns on where it stands is how an interpolation
        # becomes an injection.
        def to_arel_fields(result)
          fields =
            if result.nil? then []
            elsif result.is_a?(::Array) then result
            else [result]
            end
          fields.map do |node|
            if node.is_a?(::String) && !node.is_a?(Arel::Nodes::SqlLiteral)
              raise ArgumentError,
                "#{node.inspect} could mean SQL or a string; " \
                "sql(...) says the SQL, value(...) the string"
            end
            to_arel_field(node)
          end
        end

        def to_arel_field(node)
          case node
          when AST::Sql then node.field_arel(klass)
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
          unless relation.lateral_value
            raise ArgumentError,
              "a relation joins laterally; mark it: joins(sub.lateral, as: :top)"
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

        def check_lateral_support
          Dialect.for(klass).check_lateral(klass)
        end

        def check_full_outer_support
          return if Dialect.for(klass).full_outer_join_supported?
          raise NotImplementedError, "a full outer join has no equivalent on MySQL"
        end

        def outer_joins(called, join_class, args, alias_name, &block)
          if args.first.is_a?(ActiveRecord::Relation)
            return joins(build_lateral_join(args.first, join_class, alias_name, &block))
          end
          return joins(build_join_node(args.first, join_class, alias_name, &block)) if block

          raise ArgumentError,
            "#{called} takes a table and the block that joins it; an association " \
            "is what joins and left_outer_joins read"
        end

        # Arel has a node for every other join and none for this one, and INNER
        # JOIN with no ON -- which is a cross join on SQLite and MySQL -- is a
        # syntax error on PostgreSQL.  So the SQL is written here, the second
        # place in the gem that writes any: the keyword is fixed and the names
        # are quoted by the adapter, so nothing of the caller's is in it.
        def build_cross_join(target_table, alias_name)
          joined = klass.with_connection do |connection|
            name = connection.quote_table_name(target_table.to_s)
            alias_name ? "#{name} #{connection.quote_table_name(alias_name.to_s)}" : name
          end
          Arel::Nodes::StringJoin.new(Arel.sql("CROSS JOIN #{joined}"))
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
        super(result.transform_values { |value| to_arel_field(value) })
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
            end.join(", ")
          end
        end
    end
  end
end
