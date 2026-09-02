# frozen_string_literal: true

# BigDecimal is refined below and is a bundled gem, so nothing loads it
# before this file does.
require "bigdecimal"
require "active_record/refined/ast"

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
      #   The column under an alias: `AS "name"`.  A number or a string takes
      #   it too, for a literal in a select list; {BlockContext#value} carries
      #   the literals that have no `as` of their own.  The alias is quoted,
      #   so the name asked for is the name that comes back on every adapter;
      #   `quote: false` writes it bare, for a schema that wants the folding,
      #   and then it has to be a plain name.
      #   @param alias_name [Symbol, String]
      #   @param quote [Boolean]
      #   @return [AST::As]
      #   @example
      #     Author.select { :name.as(:author) }   # "authors"."name" AS "author"
      #     Node.select { [:id, 0.as(:depth)] }   # 0 AS "depth"
      #     Post.select { [:title, "draft".as(:state)] }   # 'draft' AS "state"

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

      # true, false and nil are refined not for the query's sake but for the
      # mistake's: their own & | ^ answer a bare boolean, so Ruby reads
      # `:active == true & cond` as `:active == (true & cond)` and the
      # condition vanishes without an error.  Beside a column or a node of
      # the query's they refuse instead; over plain values they stay Ruby's
      # through super, so a flag computed in the block still computes.
      [TrueClass, FalseClass, NilClass].each do |klass|
        refine klass do
          def &(other)
            return super unless other.is_a?(::Symbol) || other.is_a?(AST::Node)
            AST.refuse_ruby_operator(self, :&)
          end

          def |(other)
            return super unless other.is_a?(::Symbol) || other.is_a?(AST::Node)
            AST.refuse_ruby_operator(self, :|)
          end

          def ^(other)
            return super unless other.is_a?(::Symbol) || other.is_a?(AST::Node)
            AST.refuse_ruby_operator(self, :^)
          end
        end
      end
    end
  end
end
