# frozen_string_literal: true

require "active_record/refined/ast/node"

module ActiveRecord
  module Refined
    module AST
      # GROUP BY GROUPING SETS / ROLLUP / CUBE: several groupings asked for at
      # once, the totals of each coming back beside the rows.  PostgreSQL has
      # all three and the MySQL family rollup alone; the block raises for the
      # rest before it gets this far.
      #
      # Each set is a list of its own, so grouping_sets takes lists and rollup
      # and cube take the columns themselves.
      class GroupingSets < Node
        # @private
        KINDS = {
          grouping_sets: Arel::Nodes::GroupingSet,
          rollup: Arel::Nodes::RollUp,
          cube: Arel::Nodes::Cube,
        }.freeze

        # @private
        attr_reader :kind, :sets

        def initialize(kind, sets)
          raise ArgumentError, "#{kind} needs something to group by" if sets.empty?
          @kind = kind
          @sets = sets
        end

        # @private
        def to_arel(table, model)
          return with_rollup(table, model) if Dialect.for(model).grouping_by_with_rollup?

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
    end
  end
end
