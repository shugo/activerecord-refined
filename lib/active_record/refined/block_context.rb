# frozen_string_literal: true

require "active_record/refined/ast"
require "active_record/refined/dialect"

module ActiveRecord
  module Refined
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
      # `JSON_ARRAYAGG` on the MySQL family and Oracle; SQL Server has none.
      # What it gives is JSON, which compares as a dug value does.
      # @return [AST::JsonAggregate]
      # @example
      #   Post.group { :author_id }.select { json_arrayagg(:title).as(:titles) }
      def json_arrayagg(value)
        AST::JsonAggregate.new(:arrayagg, [value])
      end

      # The rows of a group gathered into one JSON object, a key and a value
      # from each, named as {#json_arrayagg} is; SQL Server has none.
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

      # A JSON array built in the row from the values given.  SQL Server
      # spells the pair its own way and is not carried yet.
      # @return [AST::JsonBuild]
      # @example
      #   Post.select { json_array(:title, :likes).as(:pair) }
      def json_array(*values)
        AST::JsonBuild.new(:array, values)
      end

      # A JSON object built in the row from a hash whose values are
      # expressions.  SQL Server spells the pair its own way and is not
      # carried yet.
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
      #   `ATAN2(y, x)`: `ATN2` on SQL Server.
      #   @return [AST::Function]
      # @!method ceil(x)
      #   `CEIL(x)`: `CEILING` on SQL Server.
      #   @return [AST::Function]
      # @!method coalesce(*values)
      #   `COALESCE(a, b, ...)`: the first that is not NULL.
      #   @return [AST::Function]
      # @!method concat(*strings)
      #   `CONCAT(a, b, ...)`.  Oracle's takes exactly two.
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
      #   `LENGTH(string)`: `LEN` on SQL Server.  What it counts is the
      #   family's own -- bytes on MySQL, characters elsewhere, and `LEN`
      #   leaves trailing spaces out; {#char_length} is the portable count.
      #   @return [AST::Function]
      # @!method ln(x)
      #   `LN(x)`: `LOG` on SQL Server.
      #   @return [AST::Function]
      # @!method log(base, x)
      #   `LOG(base, x)`.  SQL Server takes the arguments the other way round, and is refused.
      #   @return [AST::Function]
      # @!method lower(string)
      #   `LOWER(string)`.
      #   @return [AST::Function]
      # @!method ltrim(string)
      #   `LTRIM(string)`.
      #   @return [AST::Function]
      # @!method mod(x, y)
      #   `MOD(x, y)`.  SQL Server has only the % operator.
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
      #   `SUBSTR(string, from, length)`: `SUBSTRING` on SQL Server, which insists on the length.
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
      #   `LOG2(x)`.  PostgreSQL and Oracle have none -- `log(2, x)` is their spelling -- and SQL Server has neither.
      #   @return [AST::Function]
      # @!method log10(x)
      #   `LOG10(x)`.  Oracle has none.
      #   @return [AST::Function]
      # @!method trunc(x, places = 0)
      #   `TRUNC(x, places)`: `TRUNCATE` on MySQL, which insists on the places.  SQL Server has none.
      #   @return [AST::Function]
      # @!method now
      #   `NOW()`.  SQLite, Oracle and SQL Server have none; {#current_timestamp} reaches all three.
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
  end
end
