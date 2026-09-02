# frozen_string_literal: true

module ActiveRecord
  module Refined
    module AST
      # The conditions a column or an expression can be put in.  Every one
      # gives back a condition that combines with `&`, `|` and `!`, and the
      # comparisons quote a Ruby value on the right the way Active Record
      # does, or take a column, an expression or a subquery there.
      #
      # @example
      #   Author.where { :age.between?(20, 40) & :name.like?("A%") }
      #   Author.where { :id.in?(Post.select(:author_id)) }
      #
      # Predicate builders shared by symbols, qualified columns and
      # expressions. Imported into the Symbol refinement with
      # Refinement#import_methods, so every method must be defined with def.
      module Predications
        # `=`.  A value, a column, an expression or a scalar subquery on the right; `nil` is refused, since `= NULL` is never true -- {#null?} is the spelling.
        # @return [AST::Predicate]
        # @example
        #   Author.where { :name == "alice" }
        #   Author.where { :age == Author.select { max(:age) } }
        #
        # == and != mean SQL = and <>, and = NULL is never true there, so nil
        # is rejected rather than silently rewritten to IS NULL.  null? builds
        # its node directly and stays clear of this check.
        def ==(other)
          if other.nil?
            raise ArgumentError, "== does not take nil; use null? instead"
          end
          Comparison.new(self, :==, other)
        end

        # `!=`; `nil` is refused, as with `==`.
        # @return [AST::Predicate]
        def !=(other)
          if other.nil?
            raise ArgumentError, "!= does not take nil; use !null? instead"
          end
          Comparison.new(self, :!=, other)
        end

        # `>`.
        # @return [AST::Predicate]
        def >(other)
          Comparison.new(self, :>, other)
        end

        # `>=`.
        # @return [AST::Predicate]
        def >=(other)
          Comparison.new(self, :>=, other)
        end

        # `<`.
        # @return [AST::Predicate]
        def <(other)
          Comparison.new(self, :<, other)
        end

        # `<=`.
        # @return [AST::Predicate]
        def <=(other)
          Comparison.new(self, :<=, other)
        end

        # A regular expression match: `~` on PostgreSQL, `REGEXP` on MySQL, and what the adapter has elsewhere.  A Ruby Regexp's source is the pattern.
        # @param pattern [Regexp, String]
        # @return [AST::Predicate]
        # @example
        #   Author.where { :name =~ /^A/ }
        def =~(pattern)
          Match.new(self, pattern)
        end

        # The negated regular expression match.
        # @return [AST::Predicate]
        def !~(pattern)
          Match.new(self, pattern, negated: true)
        end

        # `IS NULL`.
        # @return [AST::Predicate]
        # @example
        #   Author.where { :country.null? }
        #
        # `!` negates any predicate, so these are here for the four that SQL
        # spells for itself: IS NOT NULL rather than NOT (... IS NULL), and
        # likewise NOT IN and NOT LIKE.  They mean the same thing either way,
        # including when the column is NULL; what they save is the reading.
        def null?
          Comparison.new(self, :==, nil)
        end

        # `IS NOT NULL`.
        # @return [AST::Predicate]
        def not_null?
          Comparison.new(self, :!=, nil)
        end

        # `IS TRUE`: true of the rows where the boolean is true, false where it is false or NULL -- where `== true` would be NULL.
        # @return [AST::Predicate]
        # @example
        #   Post.where { :published.true? }
        #
        # IS TRUE and IS FALSE differ from a comparison against the literal in
        # what they make of NULL: `flag = TRUE` is itself NULL there, and a
        # NULL predicate selects nothing, while these two answer false.  So the
        # difference shows in the negations: `not_true?` keeps the NULL rows
        # that `!(:flag == true)` drops.
        def true?
          TruthValue.new(self, true)
        end

        # `IS NOT TRUE`: keeps the NULL rows that `!(:flag == true)` drops.
        # @return [AST::Predicate]
        def not_true?
          TruthValue.new(self, true, negated: true)
        end

        # `IS FALSE`.
        # @return [AST::Predicate]
        def false?
          TruthValue.new(self, false)
        end

        # `IS NOT FALSE`.
        # @return [AST::Predicate]
        def not_false?
          TruthValue.new(self, false, negated: true)
        end

        # `IN (...)`: an array of values, a range, or a relation as a subquery.
        # @param values [Array, Range, ActiveRecord::Relation]
        # @return [AST::Predicate]
        # @example
        #   Author.where { :country.in?(%w[JP US]) }
        #   Author.where { :id.in?(Post.select(:author_id)) }
        def in?(values)
          In.new(self, values)
        end

        # `NOT IN (...)`.
        # @return [AST::Predicate]
        def not_in?(values)
          In.new(self, values, negated: true)
        end

        # `BETWEEN min AND max`, with either end a value, a column or an expression.
        # @return [AST::Predicate]
        # @example
        #   Author.where { :age.between?(20, 40) }
        #
        # Not min..max: an endpoint may be an expression, which Range would
        # refuse to hold, since expressions do not compare among themselves.
        def between?(min, max)
          In.new(self, In::QuotedRange.new(min, max, false))
        end

        # `NOT BETWEEN min AND max`.
        # @return [AST::Predicate]
        def not_between?(min, max)
          In.new(self, In::QuotedRange.new(min, max, false), negated: true)
        end

        # `CASE column WHEN value THEN ...`: a CASE with this as the operand, each `when` a value it is compared against, followed by `then` and finally `else`.
        # @return [AST::Case::When]
        # @example
        #   Author.select { :country.when("JP").then("Japan").else("elsewhere").as(:where) }
        #
        # CASE with this as the operand, compared against each `when`:
        # `:age.when(10).then(1).else(0)`.  The other shape, where each `when`
        # carries its own condition, starts at `case_when`.
        def when(value = nil, &block)
          Case.new(self).when(value, &block)
        end

        # `LIKE pattern`, the pattern as written: `%` and `_` are its wildcards.
        # @param pattern [String]
        # @return [AST::Predicate]
        # @example
        #   Author.where { :name.like?("A%") }
        def like?(pattern)
          Like.new(self, pattern)
        end

        # `NOT LIKE pattern`.
        # @return [AST::Predicate]
        def not_like?(pattern)
          Like.new(self, pattern, negated: true)
        end

        # A case-insensitive `LIKE`: `ILIKE` on PostgreSQL, and `LIKE` over both sides lower-cased elsewhere.
        # @return [AST::Predicate]
        def ilike?(pattern)
          Like.new(self, pattern, nil, case_sensitive: false)
        end

        # The negated case-insensitive `LIKE`.
        # @return [AST::Predicate]
        def not_ilike?(pattern)
          Like.new(self, pattern, nil, case_sensitive: false, negated: true)
        end

        # Case-insensitive equality: `LOWER(column) = LOWER(value)`.
        # @return [AST::Predicate]
        # @example
        #   Author.where { :name.casecmp?("Alice") }
        #
        # Case-insensitive equality, folded on both sides rather than left to
        # the collation, so it means the same thing on every adapter.
        def casecmp?(value)
          if value.nil?
            raise ArgumentError, "casecmp? does not take nil; use null? instead"
          end
          Comparison.new(Function.new("LOWER", [self]), :==,
                         Function.new("LOWER", [value]))
        end

        # `IS DISTINCT FROM`: `!=` that treats NULL as a value.  `IS NOT` on SQLite, `NOT <=>` on MySQL.
        # @return [AST::Predicate]
        #
        # Null-safe comparison: unlike = and <>, these treat NULL as a value,
        # so not_distinct_from? is the one equality that may take nil.
        def distinct_from?(value)
          DistinctFrom.new(self, value, negated: true)
        end

        # `IS NOT DISTINCT FROM`: `=` that treats NULL as a value, so this is the one equality that takes `nil`.
        # @return [AST::Predicate]
        # @example
        #   Author.where { :country.not_distinct_from?(nil) }
        def not_distinct_from?(value)
          DistinctFrom.new(self, value)
        end

        # `LIKE 'prefix%'`, the prefix escaped so that a `%` or `_` in it is itself; several prefixes are `OR`ed.
        # @return [AST::Predicate]
        # @example
        #   Author.where { :name.start_with?("A", "B") }
        def start_with?(*prefixes)
          if prefixes.empty?
            raise ArgumentError, "start_with? needs at least one prefix"
          end
          Like.any(self, prefixes.map { |prefix| "#{Like.escape(prefix)}%" })
        end

        # `LIKE '%suffix'`, escaped as {#start_with?} escapes.
        # @return [AST::Predicate]
        def end_with?(*suffixes)
          if suffixes.empty?
            raise ArgumentError, "end_with? needs at least one suffix"
          end
          Like.any(self, suffixes.map { |suffix| "%#{Like.escape(suffix)}" })
        end

        # `LIKE '%substring%'`, escaped as {#start_with?} escapes.
        # @return [AST::Predicate]
        # @example
        #   Post.where { :title.include?("ruby") }
        def include?(substring)
          Like.new(self, "%#{Like.escape(substring)}%", Like::ESCAPE)
        end

        # Whether a PostgreSQL array column holds the element: `@> ARRAY[element]`.
        # @return [AST::Predicate]
        # @example
        #   Post.where { :tags.member?("ruby") }
        #
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

        # Whether an array column holds every element given: `@>`.
        # @return [AST::Predicate]
        def superset?(elements)
          ArrayPredicate.new(self, :"@>", ArrayPredicate.elements(elements, "superset?"))
        end

        # Whether every element of an array column is among those given: `<@`.
        # @return [AST::Predicate]
        def subset?(elements)
          ArrayPredicate.new(self, :"<@", ArrayPredicate.elements(elements, "subset?"))
        end

        # Whether an array column and the elements given share any: `&&`.
        # @return [AST::Predicate]
        # @example
        #   Post.where { :tags.intersect?(%w[ruby sql]) }
        def intersect?(elements)
          ArrayPredicate.new(self, :"&&", ArrayPredicate.elements(elements, "intersect?"))
        end

        # The JSON at a path into a JSON column, still JSON -- to be dug further, compared with a Ruby value, or asked {#key?} and the rest.  A string or a symbol steps into an object, an integer into an array.  `#>` on PostgreSQL, `JSON_EXTRACT` on MySQL, `->` on SQLite.
        # @return [AST::JsonPath]
        # @example
        #   Doc.select { :meta.dig(:author).as(:author) }
        #   Doc.where { :meta.dig(:author).key?(:name) }
        #
        # Reading inside a JSON document, by the name of what Hash does.  A
        # string or symbol steps into an object, an integer into an array, and
        # what comes back is still JSON, the way Hash#dig hands back the
        # structure itself -- for a document to be dug into further or asked
        # the JSON questions.  dig_text gives the value as text instead,
        # which is what a comparison wants.
        def dig(*path)
          JsonPath.new(self, path)
        end

        # The value at a path as text, which is what a comparison against a string wants where the JSON type would not do: `#>>` on PostgreSQL, `JSON_UNQUOTE(JSON_EXTRACT(...))` on MySQL, `->>` on SQLite.
        # @return [AST::JsonPath]
        # @example
        #   Doc.where { :meta.dig_text(:author, :name) == "alice" }
        def dig_text(*path)
          JsonPath.new(self, path, json_value: false)
        end

        # The document without the keys given, as Hash#except gives it; an expression, for `update_all` to write back.
        # @return [AST::JsonExcept]
        # @example
        #   Doc.update_all { { meta: :meta.except(:draft) } }
        #
        # Keys taken out of a JSON document, by the name of what Hash does,
        # and taking keys as Hash#except takes them.  Like bury it gives back
        # the document changed rather than writing it anywhere.
        def except(*keys)
          JsonExcept.new(self, keys)
        end

        # The document with a value set at a path, as {#dig} reads one; an expression, for `update_all` to write back.
        # @return [AST::JsonSet]
        # @example
        #   Doc.update_all { { meta: :meta.bury(:author, :name, "alice") } }
        #
        # What dig reads, bury sets: the last argument is the value and the
        # rest are the path to it.  The document comes back changed rather
        # than being written anywhere, which update_all is for.
        def bury(*path, value)
          JsonSet.new(self, path, value)
        end

        # Whether the document contains the Ruby document given, which SQL calls containment: `@>` on PostgreSQL, `JSON_CONTAINS` on MySQL.  SQLite and MariaDB have none.
        # @return [AST::Predicate]
        # @example
        #   Doc.where { :meta.contains?(author: { name: "alice" }) }
        #
        # Whether the document holds what is given, which SQL calls
        # containment.  SQLite has no equivalent.
        def contains?(value)
          JsonContains.new(self, value)
        end

        # Whether the object has the key, as Hash#key? asks.
        # @return [AST::Predicate]
        # @example
        #   Doc.where { :meta.key?(:author) }
        #
        # Whether the key is there at all, as Hash#key? asks.  Hash has
        # has_key? too; one name is enough, and this is the one Ruby's own
        # style prefers.
        def key?(key)
          JsonHasKey.new(self, key)
        end

        # The keys of the object as a JSON array, as Hash#keys gives them.  Oracle and SQL Server have none.
        # @return [AST::JsonKeys]
        #
        # The keys of the document, as Hash#keys gives them: a JSON array.
        def keys
          JsonKeys.new(self)
        end
      end
    end
  end
end
