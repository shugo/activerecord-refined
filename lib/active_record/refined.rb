# frozen_string_literal: true

module ActiveRecord
  module Refined
    # What a symbol answers to inside a block.  A symbol names a column
    # there -- `:age` is `"users"."age"` -- and the methods below build a
    # condition, an expression or an ordering from it.  Every one of them is
    # a refinement, so it exists inside a `where`, `select`, `having`,
    # `order`, `group`, `joins`, `update_all` or `upsert_all` block and
    # nowhere else.
    #
    # The comparisons and the rest of the conditions are listed under
    # {AST::Predications}, the arithmetic under {AST::Arithmetics}; a number
    # or a string in a block takes `as` too, for a literal in a select list
    # -- `0.as(:depth)` -- and a number on the left of an operator builds the
    # same expression a column on the left would.
    #
    # @example A column compared, aliased and ordered
    #   Author.where { :age >= 18 }
    #   Author.select { :name.as(:author) }
    #   Author.order { :age.desc.nulls_last }
    # @example A column of another table, and a collation
    #   Author.joins(:posts) { :posts[:author_id] == :authors[:id] }
    #   Author.where { :name.collate(:nocase) == "alice" }
    module BlockSyntax
      # @!parse include AST::Predications
      # @!parse include AST::Arithmetics

      # @!method as(alias_name, quote: true)
      #   The column under an alias: `AS "name"`.  The alias is quoted, so
      #   the name asked for is the name that comes back on every adapter;
      #   `quote: false` writes it bare, for a schema that wants the folding,
      #   and then it has to be a plain name.
      #   @param alias_name [Symbol, String]
      #   @param quote [Boolean]
      #   @return [AST::As]
      #   @example
      #     Author.select { :name.as(:author) }   # "authors"."name" AS "author"

      # @!method asc
      #   An ascending ordering, which takes `nulls_first` and `nulls_last`.
      #   @return [AST::Ordering]
      #   @example
      #     Author.order { :country.asc.nulls_last }

      # @!method desc
      #   A descending ordering, which takes `nulls_first` and `nulls_last`.
      #   @return [AST::Ordering]
      #   @example
      #     Post.order { :likes.desc }

      # @!method collate(name)
      #   The column under a collation, for a comparison or an ordering:
      #   `"name" COLLATE nocase`.  The name is the database's own and not
      #   portable; PostgreSQL quotes it, the others take it bare and refuse
      #   one that is not a plain identifier.
      #   @param name [Symbol, String] the collation's name
      #   @return [AST::Collate]
      #   @example
      #     Author.where { :name.collate(:nocase) == "alice" }
      #     Author.order { :name.collate(:"en-US-x-icu").asc }   # PostgreSQL

      # @!method [](column_name)
      #   A column of another table: `:posts[:author_id]` is
      #   `"posts"."author_id"`, for a join condition or a query over a join.
      #   @param column_name [Symbol]
      #   @return [AST::Column]
      #   @example
      #     Author.joins(:posts) { :posts[:author_id] == :authors[:id] }

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

    # What a block can call: the aggregates, the functions, CASE, and the
    # escape hatches.  A block is evaluated with one of these as `self`, so
    # its methods are called bare -- `count(:*)`, `upper(:name)` -- and each
    # gives back an expression that compares, aliases and orders like a
    # column does (see {BlockSyntax}).
    #
    # Where a function is spelled differently from one database to the next,
    # the method names the one meaning and the adapter gets its own
    # spelling; where a database has no equivalent, the method raises
    # `NotImplementedError` as the block is read, rather than leaving the
    # database to reject the SQL.
    #
    # @example
    #   Author.select { [upper(:name).as(:author), count(:*).as(:posts)] }
    #   Author.having { count(:*) > 1 }
    class BlockContext
      # The model is only consulted to learn which adapter the query is being
      # built for, which is what decides how a scalar function is spelled.
      # @api private
      def initialize(model)
        @model = model
      end

      # @!group Aggregates

      # @!method sum(column, distinct: false)
      #   `SUM(column)`, or `SUM(DISTINCT column)`.
      #   @return [AST::Aggregate]
      # @!method avg(column, distinct: false)
      #   `AVG(column)`, or `AVG(DISTINCT column)`.
      #   @return [AST::Aggregate]
      # @!method min(column)
      #   `MIN(column)`.
      #   @return [AST::Aggregate]
      # @!method max(column)
      #   `MAX(column)`.
      #   @return [AST::Aggregate]
      # @private
      AGGREGATE_FUNCTIONS = {
        sum: :sum, avg: :average, min: :minimum, max: :maximum,
      }.freeze

      # count, sum and avg take distinct: true, for the aggregate over each
      # value once; min and max would answer the same with or without it,
      # so they take no such thing.
      AGGREGATE_FUNCTIONS.each do |name, arel_func|
        if AST::Aggregate::DISTINCT_FUNCTIONS.include?(arel_func)
          define_method(name) do |column, distinct: false|
            AST::Aggregate.new(column, arel_func, distinct: distinct)
          end
        else
          define_method(name) { |column| AST::Aggregate.new(column, arel_func) }
        end
      end

      # `COUNT(column)`; `:*` for `COUNT(*)`, `distinct: true` for
      # `COUNT(DISTINCT column)`.  Every aggregate takes {AST::Aggregate#filter}
      # for the rows it is taken over, and {AST::Windowing#over} for a window.
      # @param column [Symbol, AST::Node, :*]
      # @return [AST::Aggregate]
      # @example
      #   Author.group { :country }.having { count(:*) > 1 }
      #   Post.select { count(:author_id, distinct: true) }
      #   Author.select { count(:*).filter { :age < 50 }.as(:young) }
      def count(column, distinct: false)
        AST::Aggregate.new(column, :count, distinct: distinct)
      end

      # The rows of a group gathered into one JSON array, a value from each:
      # `jsonb_agg` on PostgreSQL, `json_group_array` on SQLite,
      # `JSON_ARRAYAGG` elsewhere.  What it gives is JSON, which compares
      # as a dug value does.
      # @return [AST::JsonAggregate]
      # @example
      #   Post.group { :author_id }.select { json_arrayagg(:title).as(:titles) }
      def json_arrayagg(value)
        AST::JsonAggregate.new(:arrayagg, [value])
      end

      # The rows of a group gathered into one JSON object, a key and a value
      # from each.
      # @return [AST::JsonAggregate]
      # @example
      #   Post.select { json_objectagg(:title, :meta.dig(:stars)).as(:stars) }
      def json_objectagg(key, value)
        AST::JsonAggregate.new(:objectagg, [key, value])
      end

      # The strings of a group joined into one, a separator between:
      # `STRING_AGG` on PostgreSQL and SQL Server, `group_concat` on SQLite,
      # `GROUP_CONCAT` on MySQL, `LISTAGG` on Oracle.  Takes
      # {AST::StringAggregate#order} for the order they are joined in.
      # @param separator [String] the comma GROUP_CONCAT defaults to, unless given
      # @return [AST::StringAggregate]
      # @example
      #   Post.group { :author_id }.
      #     select { string_agg(:title, ", ").order(:title).as(:titles) }
      def string_agg(value, separator = ",")
        AST::StringAggregate.new(value, separator)
      end

      # @!endgroup
      # @!group JSON

      # A JSON array built in the row from the values given.
      # @return [AST::JsonBuild]
      # @example
      #   Post.select { json_array(:title, :likes).as(:pair) }
      def json_array(*values)
        AST::JsonBuild.new(:array, values)
      end

      # A JSON object built in the row from a hash whose values are
      # expressions.
      # @param pairs [Hash{Symbol, String => Object}]
      # @return [AST::JsonBuild]
      # @example
      #   Post.select { json_object(title: :title, stars: :meta.dig(:stars)).as(:doc) }
      def json_object(pairs = {})
        AST::JsonBuild.new(:object, pairs)
      end

      # @!endgroup
      # @!group Scalar functions

      # @!method abs(x)
      #   `ABS(x)`.
      #   @return [AST::Function]
      # @!method acos(x)
      #   `ACOS(x)`.
      #   @return [AST::Function]
      # @!method asin(x)
      #   `ASIN(x)`.
      #   @return [AST::Function]
      # @!method atan(x)
      #   `ATAN(x)`.
      #   @return [AST::Function]
      # @!method atan2(y, x)
      #   `ATAN2(y, x)`.
      #   @return [AST::Function]
      # @!method ceil(x)
      #   `CEIL(x)`.
      #   @return [AST::Function]
      # @!method coalesce(*values)
      #   `COALESCE(a, b, ...)`: the first that is not NULL.
      #   @return [AST::Function]
      # @!method concat(*strings)
      #   `CONCAT(a, b, ...)`.
      #   @return [AST::Function]
      # @!method cos(x)
      #   `COS(x)`.
      #   @return [AST::Function]
      # @!method exp(x)
      #   `EXP(x)`.
      #   @return [AST::Function]
      # @!method floor(x)
      #   `FLOOR(x)`.
      #   @return [AST::Function]
      # @!method length(string)
      #   `LENGTH(string)`.
      #   @return [AST::Function]
      # @!method ln(x)
      #   `LN(x)`.
      #   @return [AST::Function]
      # @!method log(base, x)
      #   `LOG(base, x)`.
      #   @return [AST::Function]
      # @!method lower(string)
      #   `LOWER(string)`.
      #   @return [AST::Function]
      # @!method ltrim(string)
      #   `LTRIM(string)`.
      #   @return [AST::Function]
      # @!method mod(x, y)
      #   `MOD(x, y)`.
      #   @return [AST::Function]
      # @!method nullif(x, y)
      #   `NULLIF(x, y)`: NULL where the two are equal, x otherwise.
      #   @return [AST::Function]
      # @!method power(x, y)
      #   `POWER(x, y)`.
      #   @return [AST::Function]
      # @!method replace(string, from, to)
      #   `REPLACE(string, from, to)`.
      #   @return [AST::Function]
      # @!method round(x, places = 0)
      #   `ROUND(x, places)`.
      #   @return [AST::Function]
      # @!method rtrim(string)
      #   `RTRIM(string)`.
      #   @return [AST::Function]
      # @!method sign(x)
      #   `SIGN(x)`.
      #   @return [AST::Function]
      # @!method sin(x)
      #   `SIN(x)`.
      #   @return [AST::Function]
      # @!method sqrt(x)
      #   `SQRT(x)`.
      #   @return [AST::Function]
      # @!method substr(string, from, length = nil)
      #   `SUBSTR(string, from, length)`.
      #   @return [AST::Function]
      # @!method tan(x)
      #   `TAN(x)`.
      #   @return [AST::Function]
      # @!method trim(string)
      #   `TRIM(string)`.
      #   @return [AST::Function]
      # @!method upper(string)
      #   `UPPER(string)`.
      #   @return [AST::Function]
      # @!method degrees(x)
      #   `DEGREES(x)`.  Oracle has none.
      #   @return [AST::Function]
      # @!method radians(x)
      #   `RADIANS(x)`.  Oracle has none.
      #   @return [AST::Function]
      # @!method pi
      #   `PI()`.  Oracle has none.
      #   @return [AST::Function]
      # @!method char_length(string)
      #   `CHAR_LENGTH(string)`: `LENGTH` on SQLite and Oracle, `LEN` on SQL Server.
      #   @return [AST::Function]
      # @!method greatest(*values)
      #   `GREATEST(a, b, ...)`: `MAX` on SQLite.
      #   @return [AST::Function]
      # @!method least(*values)
      #   `LEAST(a, b, ...)`: `MIN` on SQLite.
      #   @return [AST::Function]
      # @!method log2(x)
      #   `LOG2(x)`.  PostgreSQL and Oracle have none; `log(2, x)` is their spelling.
      #   @return [AST::Function]
      # @!method log10(x)
      #   `LOG10(x)`.  Oracle has none.
      #   @return [AST::Function]
      # @!method trunc(x, places = 0)
      #   `TRUNC(x, places)`: `TRUNCATE` on MySQL, which insists on the places.
      #   @return [AST::Function]
      # @!method now
      #   `NOW()`.  SQLite and Oracle have none; {#current_timestamp} reaches both.
      #   @return [AST::Function]
      # @!method bit_and(column)
      #   `BIT_AND(column)`, an aggregate.  PostgreSQL and MySQL have it.
      #   @return [AST::Function]
      # @!method bit_or(column)
      #   `BIT_OR(column)`, an aggregate.  PostgreSQL and MySQL have it.
      #   @return [AST::Function]
      # @!method bit_xor(column)
      #   `BIT_XOR(column)`, an aggregate.  PostgreSQL and MySQL have it.
      #   @return [AST::Function]
      # @!method date_trunc(field, timestamp)
      #   `date_trunc('day', timestamp)`.  PostgreSQL has it; the others do not.
      #   @return [AST::Function]
      # @!method rand
      #   `RAND()`, a random number per row: `RANDOM()` on PostgreSQL and SQLite.  Oracle and SQL Server have none.
      #   @return [AST::Function]
      # @!method format(template, *values)
      #   printf-style `FORMAT(template, ...)`.  PostgreSQL and SQLite have it; MySQL's FORMAT is a different function, reached through {#fn}.
      #   @return [AST::Function]
      #
      # Scalar functions, defined as real methods so that a typo is a
      # NoMethodError and a name Kernel also answers to (format, hash, test)
      # cannot quietly mean something else.  Where one is spelled other than as
      # its plain upper-cased name, and where a family has no equivalent, is
      # the dialect's to say; here is only the list of them.
      # @private
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

      # @!endgroup
      # @!group Datetime value functions

      # @!method current_timestamp(precision = nil)
      #   `CURRENT_TIMESTAMP`, the server's clock in the session's zone; the
      #   portable spelling of what {#now} means.  A precision --
      #   `current_timestamp(3)` -- goes into parentheses, which SQLite and
      #   SQL Server refuse.
      #   @return [AST::DatetimeValueFunction]
      #   @example
      #     Post.where { :published_at <= current_timestamp }
      #     Post.where { :created_at > current_timestamp - 7.days }
      # @!method current_time(precision = nil)
      #   `CURRENT_TIME`.  SQL Server has none.
      #   @return [AST::DatetimeValueFunction]
      # @!method localtime(precision = nil)
      #   `LOCALTIME`.  SQLite and SQL Server have none.
      #   @return [AST::DatetimeValueFunction]
      # @!method localtimestamp(precision = nil)
      #   `LOCALTIMESTAMP`.  SQLite and SQL Server have none.
      #   @return [AST::DatetimeValueFunction]
      #
      # The datetime value functions, as the SQL grammar calls them.  These
      # the grammar has bare -- PostgreSQL and SQLite reject them written with
      # parentheses -- and the one thing that does go into parentheses is an
      # optional precision, current_timestamp(3), which current_date never
      # takes and SQLite never accepts.  The table reads like
      # SCALAR_FUNCTIONS; current_timestamp is the portable spelling of what
      # now means, reaching SQLite where now does not.
      # @private
      DATETIME_VALUE_FUNCTIONS = %i[
        current_date current_time current_timestamp localtime localtimestamp
      ].freeze

      # `CURRENT_DATE`, today in the session's zone -- UTC where Active
      # Record has set it so.  Takes no precision.  SQL Server has none.
      # @return [AST::DatetimeValueFunction]
      # @example
      #   Task.where { :due_on < current_date }
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

      # `EXTRACT(field FROM expr)`: a year, a month, a day of a date.  The
      # field is a keyword and has to be a plain name.  SQLite and SQL Server
      # have none.
      # @param field [Symbol, String] `:year`, `:month`, `:day`, `:hour`, ...
      # @return [AST::Extract]
      # @example
      #   Post.where { extract(:year, :created_at) == 2026 }
      #
      # The field is a keyword, not a value, so it has to be a plain name;
      # the node checks it.  SQLite spells all of this as strftime formats,
      # which no renaming carries, so it raises there -- after the node is
      # built, so that a bad field is an ArgumentError on every adapter.
      def extract(field, expr)
        node = AST::Extract.new(field, expr)
        unless dialect.extract_supported?
          raise NotImplementedError,
            "extract has no equivalent on #{@model.connection_db_config.adapter}"
        end
        node
      end

      # @!endgroup
      # @!group Grouping

      # `GROUP BY GROUPING SETS ((a), (b), ())`: several groupings in one
      # query, an empty set for the grand total.  PostgreSQL has it; the
      # others do not.
      # @param sets [Array<Array<Symbol, AST::Node>>]
      # @return [AST::GroupingSets]
      # @example
      #   Sale.group { grouping_sets([:region], [:product], []) }
      #
      # Arel has the nodes and writes them for PostgreSQL alone, so what it
      # would raise elsewhere says nothing; this says it here, as extract
      # does, while the block is being read.
      def grouping_sets(*sets)
        grouping(:grouping_sets, sets)
      end

      # `GROUP BY ROLLUP (a, b)`: subtotals up the list and a grand total.
      # PostgreSQL has it, and the MySQL family as `WITH ROLLUP` trailing
      # the group list, which the node spells there.
      # @return [AST::GroupingSets]
      # @example
      #   Sale.group { rollup(:region, :product) }
      def rollup(*columns)
        grouping(:rollup, columns)
      end

      # `GROUP BY CUBE (a, b)`: every subtotal there is.  PostgreSQL has it;
      # the others do not.
      # @return [AST::GroupingSets]
      # @example
      #   Sale.group { cube(:region, :product) }
      def cube(*columns)
        grouping(:cube, columns)
      end

      # @!endgroup
      # @!group Conversions

      # `CAST(expr AS type)`.  The type is the adapter's own name for it --
      # `decimal(10,2)`, `double precision` -- and has to look like one;
      # whether it exists is the database's to say.
      # @param type [Symbol, String]
      # @return [AST::Cast]
      # @example
      #   Post.select { cast(:price, "decimal(10,2)").as(:price) }
      def cast(expr, type)
        AST::Cast.new(expr, type)
      end

      # @!endgroup
      # @!group Window functions

      # @!method row_number
      #   `ROW_NUMBER()`.  Means nothing without {AST::Windowing#over}, and
      #   says so.
      #   @return [AST::WindowFunction]
      #   @example
      #     Author.select { row_number.over.partition(:country).order(:age.desc).as(:rank) }
      # @!method rank
      #   `RANK()`; needs `over`.
      #   @return [AST::WindowFunction]
      # @!method dense_rank
      #   `DENSE_RANK()`; needs `over`.
      #   @return [AST::WindowFunction]
      # @!method percent_rank
      #   `PERCENT_RANK()`; needs `over`.
      #   @return [AST::WindowFunction]
      # @!method cume_dist
      #   `CUME_DIST()`; needs `over`.
      #   @return [AST::WindowFunction]
      # @!method ntile(buckets)
      #   `NTILE(buckets)`; needs `over`.
      #   @return [AST::WindowFunction]
      # @!method first_value(expr)
      #   `FIRST_VALUE(expr)`; needs `over`.
      #   @return [AST::WindowFunction]
      # @!method last_value(expr)
      #   `LAST_VALUE(expr)`; needs `over`.
      #   @return [AST::WindowFunction]
      #
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

      # `NTH_VALUE(expr, nth)`; needs `over`.
      # @return [AST::WindowFunction]
      def nth_value(expr, nth)
        AST::WindowFunction.new("NTH_VALUE", [expr, nth])
      end

      # `LAG(expr, offset, default)`: the value `offset` rows before this
      # one; needs `over`.
      # @return [AST::WindowFunction]
      # @example
      #   Post.select { (:likes - lag(:likes).over.order(:created_at)).as(:gain) }
      #
      # The offset is written out rather than left to default, so that a
      # default value cannot end up where the offset belongs.
      def lag(expr, offset = 1, default = nil)
        AST::WindowFunction.new("LAG", default.nil? ? [expr, offset] : [expr, offset, default])
      end

      # `LEAD(expr, offset, default)`: the value `offset` rows after this
      # one; needs `over`.
      # @return [AST::WindowFunction]
      def lead(expr, offset = 1, default = nil)
        AST::WindowFunction.new("LEAD", default.nil? ? [expr, offset] : [expr, offset, default])
      end

      # @!endgroup
      # @!group Escape hatches

      # Any function by name: `fn(:date_part, "year", :created_at)`.  The name
      # is written as given -- so a case-sensitive one can be spelled exactly
      # -- and has to be a plain name, optionally qualified by a schema;
      # the arguments are quoted as values unless they are columns or
      # expressions.
      # @param name [Symbol, String]
      # @return [AST::Function]
      # @example
      #   Post.select { fn(:date_part, "year", :created_at).as(:year) }
      #
      # The name is emitted as written, so a case-sensitive one can be
      # spelled exactly, and for that reason it has to be a plain name,
      # optionally qualified by a schema; anything else is refused rather
      # than written into the SQL.
      def fn(name, *args)
        AST::Function.new(
          AST.check_name(name, AST::FUNCTION_NAME, "function name").to_s, args)
      end

      # Any binary operator by its spelling: `op("&&", :tags, "{ruby,sql}")`.
      # The operator has to be made of operator characters; the operands are
      # quoted as values unless they are columns or expressions, and
      # parenthesized, since the operator's precedence is not known.
      # @param operator [String]
      # @return [AST::Operation]
      # @example
      #   Post.where { op("&&", :tags, "{ruby,sql}") }   # PostgreSQL arrays
      def op(operator, left, right)
        AST::Operation.new(operator, left, right)
      end

      # @!endgroup
      # @!group Bits

      # `BIT_COUNT(expr)`, the bits set in a number.  MySQL and PostgreSQL
      # have it; SQLite, Oracle and SQL Server do not.
      # @return [AST::Function]
      # @example
      #   Post.select { bit_count(:flags).as(:set) }
      #
      # MySQL counts the bits of a number; PostgreSQL counts those of a bit
      # string, so the argument is cast, and to bit(64) because that is what
      # makes a negative come back as MySQL has it -- 64 bits of two's
      # complement rather than as many as the column happens to be wide.
      def bit_count(expr)
        dialect.bit_count(expr, @model)
      end

      # @!endgroup
      # @!group Subqueries

      # `EXISTS (subquery)`.  The subquery is a relation, which may refer to
      # the outer row through a qualified column.
      # @param relation [ActiveRecord::Relation]
      # @return [AST::Exists]
      # @example
      #   Author.where { exists?(Post.where { :posts[:author_id] == :authors[:id] }) }
      def exists?(relation)
        AST::Exists.new(relation)
      end

      # `ANY (subquery)`, on the right of a comparison: true of the rows the
      # comparison holds for any row of the subquery.  SQLite has none.
      # @param relation [ActiveRecord::Relation]
      # @return [AST::Quantified]
      # @example
      #   Post.where { :likes > any(Post.published.select(:likes)) }
      #
      # ANY and ALL quantify a comparison over a subquery, which is what a
      # scalar subquery cannot do: it has to return the one row.  `== any`
      # is IN and `!= all` is NOT IN, so what these add is the four
      # comparisons IN has no spelling for.
      def any(relation)
        quantified("ANY", relation)
      end

      # `ALL (subquery)`, on the right of a comparison: true of the rows the
      # comparison holds for every row of the subquery.  SQLite has none.
      # @param relation [ActiveRecord::Relation]
      # @return [AST::Quantified]
      # @example
      #   Post.where { :likes >= all(Post.select(:likes)) }
      def all(relation)
        quantified("ALL", relation)
      end

      # @!endgroup
      # @!group Escape hatches

      # SQL as written, the one way a string means SQL inside a block.  `?`
      # and `:name` placeholders take quoted values, as `where` takes them.
      # @param statement [String]
      # @return [AST::Sql]
      # @example
      #   Post.where { sql("length(title) > ?", 10) }
      #   Post.select { sql("count(*) FILTER (WHERE score > 0) AS positive") }
      def sql(statement, *binds)
        AST::Sql.new(statement, binds)
      end

      # A literal where an expression is expected, quoted like any other
      # value.  A number or a string takes `as` for itself -- `0.as(:depth)`
      # -- so this is the spelling for the rest: `true`, `nil`, a date.
      # @return [AST::Value]
      # @example
      #   Node.select { [:id, value(0).as(:depth)] }
      #   Post.select { [:title, value(nil).as(:score)] }
      def value(literal)
        AST::Value.new(literal)
      end

      # The row an upsert could not insert, in the block `upsert_all` takes:
      # `"excluded"."column"` on PostgreSQL and SQLite, `VALUES(column)` on
      # MySQL.
      # @param column [Symbol]
      # @return [AST::Node]
      # @example
      #   Tally.upsert_all(rows, unique_by: :page) { { hits: :hits + excluded(:hits) } }
      def excluded(column)
        dialect.excluded(column, @model)
      end

      # @!endgroup
      # @!group CASE

      # `CASE`, in either shape: with an operand each `when` is compared
      # against, or without one, each `when` carrying its own condition.
      # `case` is a keyword, so this one is reached as `self.case`; the
      # shorthands `:age.when(...)` and {#case_when} need no receiver.
      # @return [AST::Case]
      # @example
      #   self.case(:age).when(10).then(1).else(0)
      #   self.case.when { :age >= 60 }.then { :age - 60 }
      def case(operand = nil)
        AST::Case.new(operand)
      end

      # The searched `CASE`, started at its first `when`: each `when` is a
      # condition, as a value or a block, and `then` and `else` give the
      # values.
      # @return [AST::Case::When]
      # @example
      #   Author.select { case_when { :age >= 60 }.then("senior").else("adult").as(:band) }
      #   Author.select { sum(case_when { :age >= 60 }.then(1).else(0)).as(:seniors) }
      def case_when(value = nil, &block)
        AST::Case.new.when(value, &block)
      end

      private
        # @!endgroup
        #
        # The group closes here rather than above `private`: a comment on
        # that line belongs to the `private` call, which reads no
        # directives, and the group would run on into the next module.
        #
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

    # The relation methods a block reaches, prepended to Active Record's
    # own: `where`, `select`, `having`, `order` and `group` take a block
    # beside what they take already, the joins take one for the ON, and
    # `from`, `from_cte`, `distinct_on` and `lateral` are here for what
    # Active Record has no spelling for.  Without a block each is Active
    # Record's own.
    #
    # @example
    #   Author.
    #     joins(:posts) { :posts[:author_id] == :authors[:id] }.
    #     where { :posts[:published] == true }.
    #     group { :authors[:id] }.
    #     having { count(:posts[:id]) > 1 }.
    #     order { count(:posts[:id]).desc }.
    #     select { [:name, count(:posts[:id]).as(:post_count)] }
    module QueryMethods
      # `WHERE`, from a block: a condition built with the comparisons of
      # {BlockSyntax}, combined with `&`, `|` and `!`.
      # @yieldreturn [AST::Predicate]
      # @example
      #   Author.where { :age >= 18 & :country.in?(%w[JP US]) }
      #   Author.where { !:name.like?("A%") }
      def where(opts = nil, *rest, &block)
        if block
          super(to_arel_condition(evaluate_block(&block)))
        else
          super
        end
      end

      # `SELECT`, from a block: an expression, or an array of them, each
      # aliased with `as` or left to its own name.
      # @yieldreturn [Symbol, AST::Node, Array<Symbol, AST::Node>]
      # @example
      #   Author.select { [:name, upper(:name).as(:shouted), count(:*).as(:n)] }
      def select(*fields, &block)
        if block
          super(*to_arel_fields(evaluate_block(&block)), &nil)
        else
          super
        end
      end

      # `HAVING`, from a block: a condition over the aggregates of a group.
      # @yieldreturn [AST::Predicate]
      # @example
      #   Author.group { :country }.having { count(:*) > 1 }
      def having(opts = nil, *rest, &block)
        if block
          super(to_arel_condition(evaluate_block(&block)))
        else
          super
        end
      end

      # `ORDER BY`, from a block: an ordering, or an array of them --
      # `:age.desc`, `count(:*).desc.nulls_last`, or a bare column.
      # @yieldreturn [Symbol, AST::Node, Array<Symbol, AST::Node>]
      # @example
      #   Author.order { [:country.asc.nulls_last, :age.desc] }
      def order(*args, &block)
        if block
          super(*to_arel_fields(evaluate_block(&block)), &nil)
        else
          super
        end
      end

      # `GROUP BY`, from a block: a column or an expression, an array of
      # them, or one of {BlockContext#grouping_sets}, {BlockContext#rollup}
      # and {BlockContext#cube}.
      # @yieldreturn [Symbol, AST::Node, Array<Symbol, AST::Node>]
      # @example
      #   Post.group { date_trunc("day", :created_at) }.select { [date_trunc("day", :created_at).as(:day), count(:*)] }
      def group(*args, &block)
        if block
          result = evaluate_block(&block)
          check_rollup_stands_alone(result)
          super(*to_arel_fields(result), &nil)
        else
          super
        end
      end

      # `FROM`, with a table named as a symbol and, with `as:`, selected
      # under another name; anything else is Active Record's own `from`.
      # @param value [Symbol, String, ActiveRecord::Relation]
      # @param as [Symbol, nil] the name the table is selected under
      # @example
      #   Post.from(:archived_posts, as: :posts)
      #
      # A symbol names a table, which Active Record's own from only takes as
      # a string.  With `as` it is selected under another name; when that
      # name is the model's own, from_cte says the same thing without
      # repeating it.
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

      # Selects a CTE in place of the model's own table, under the model's
      # own name, so that the columns Active Record qualifies still resolve.
      # The name has to be one `with` or `with_recursive` declares.
      # @param name [Symbol] the CTE's name
      # @example
      #   Node.with_recursive(tree: [Node.where { :id == 1 }, Node.joins(...)]).from_cte(:tree)
      #
      # The alias is not a choice -- Active Record keeps qualifying columns
      # with the table name, so the model's is the only name that works --
      # which is why it is taken from the model rather than asked for.
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

      # @private
      def from_cte_value
        @values[:from_cte]
      end

      # @private
      def from_cte_value=(name)
        assert_modifiable!
        @values[:from_cte] = name
      end

      # `SELECT DISTINCT ON (columns)`: the first row of each group the
      # order brings up.  PostgreSQL has it; the portable shape is a
      # `row_number` window in a subquery.
      # @param columns [Array<Symbol>] the columns, unless a block gives them
      # @example
      #   Post.distinct_on { :author_id }.order { [:author_id, :likes.desc] }
      #
      # Arel carries the node and refuses to write it elsewhere, the way it
      # does a regexp, so there is nothing for this to check.
      def distinct_on(*columns, &block)
        spawn.distinct_on!(*columns, &block)
      end

      # {#distinct_on} on the relation itself.
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
      # @private
      def distinct_on_values
        @values.fetch(:distinct_on, ActiveRecord::QueryMethods::FROZEN_EMPTY_ARRAY)
      end

      # @private
      def distinct_on_values=(columns)
        assert_modifiable!
        @values[:distinct_on] = columns
      end

      # Marks the relation for a `LATERAL` join, which lets the subquery see
      # the row it is joined to -- the top few rows of each group, and the
      # like.  Said on the relation, since in SQL the keyword modifies the
      # subquery rather than the join.  SQLite and MariaDB have none.
      # @example
      #   top = Post.where { :posts[:author_id] == :authors[:id] }.order { :likes.desc }.limit(1)
      #   Author.left_outer_joins(top.lateral, as: :top) { true }.select { [:name, :top[:title]] }
      def lateral
        spawn.lateral!
      end

      # {#lateral} on the relation itself.
      def lateral!
        self.lateral_value = true
        self
      end

      # @private
      def lateral_value
        @values[:lateral]
      end

      # @private
      def lateral_value=(value)
        assert_modifiable!
        @values[:lateral] = value
      end

      # `INNER JOIN`, with the `ON` from a block: `joins(:posts) { ... }`
      # joins the table named, `joins(relation) { ... }` a subquery -- a
      # lateral one when the relation is marked {#lateral}.  `as:` names the
      # table within the query, which is what makes a self join expressible.
      # Without a block it is Active Record's own `joins`.
      # @param as [Symbol, nil]
      # @example
      #   Author.joins(:posts) { :posts[:author_id] == :authors[:id] }
      #   Employee.joins(:employees, as: :managers) { :managers[:id] == :employees[:manager_id] }
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

      # `LEFT OUTER JOIN`, as {#joins} takes it.
      # @param as [Symbol, nil]
      # @example
      #   Author.left_outer_joins(:posts) { :posts[:author_id] == :authors[:id] }
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

      # `RIGHT OUTER JOIN`, as {#joins} takes it, of a table or a relation;
      # an association name is not among what it takes.
      # @param as [Symbol, nil]
      # @example
      #   Post.right_outer_joins(:authors) { :posts[:author_id] == :authors[:id] }
      #
      # The other two outer joins, which Active Record has no method for and
      # Arel has the nodes for.  The rules are joins': the block is the ON,
      # `as` names the table within the query, a relation marked `lateral`
      # joins as one.  An association name is not among them -- what Active
      # Record reads out of one is an inner or a left join and nothing else.
      def right_outer_joins(*args, as: nil, &block)
        outer_joins(:right_outer_joins, Arel::Nodes::RightOuterJoin,
                    args, as, &block)
      end

      # `FULL OUTER JOIN`, as {#right_outer_joins} takes it.  The MySQL
      # family has none.
      # @param as [Symbol, nil]
      def full_outer_joins(*args, as: nil, &block)
        check_full_outer_support
        outer_joins(:full_outer_joins, Arel::Nodes::FullOuterJoin,
                    args, as, &block)
      end

      # `CROSS JOIN`: every row of one table against every row of the
      # other, so there is no condition to give and no block to write it in.
      # @param as [Symbol, nil]
      # @example
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
      # `UPDATE`, from a block that gives a hash of column to value, where a
      # value may be an expression built from the row: `{ likes: :likes + 1 }`.
      # Without a block it is Active Record's own, where `likes: :likes`
      # sets the column to the symbol.
      # @yieldreturn [Hash{Symbol => Object}]
      # @example
      #   Post.where { :published == true }.update_all { { likes: :likes + 1 } }
      #   Post.update_all { { title: upper(:title) } }
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

      # `INSERT ... ON CONFLICT DO UPDATE`, with a block for what happens to
      # a row that is already there: a hash of column to value, where
      # {BlockContext#excluded} is the row that could not be inserted.  Takes
      # the block or `on_duplicate:`, not both.
      # @yieldreturn [Hash{Symbol => Object}]
      # @example
      #   Tally.upsert_all(rows, unique_by: :page) { { hits: :hits + excluded(:hits) } }
      #
      # upsert_all's on_duplicate takes SQL text and nothing else, so this is
      # the one place the DSL writes the SQL out itself rather than handing
      # Arel a tree.
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
