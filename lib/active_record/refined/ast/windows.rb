# frozen_string_literal: true

require "active_record/refined/ast/node"

module ActiveRecord
  module Refined
    module AST
      # OVER, on the two things that can carry a window: an aggregate, and a
      # function.
      module Windowing
        # `OVER ()`, an empty window to be filled by {Over#partition},
        # {Over#order}, {Over#rows} and {Over#range}.
        # @return [AST::Over]
        # @example
        #   Author.select { avg(:age).over.partition(:country).as(:country_average) }
        #   Post.select { sum(:likes).over.order(:created_at).rows(..0).as(:running) }
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

        # @private
        attr_reader :function, :partitions, :orders, :frame

        def initialize(function, partitions = [], orders = [], frame = nil)
          @function = function
          @partitions = partitions
          @orders = orders
          @frame = frame
        end

        # `PARTITION BY`, the columns or expressions given.
        # @return [AST::Over]
        def partition(*exprs)
          raise ArgumentError, "partition needs an expression" if exprs.empty?
          Over.new(function, partitions + exprs, orders, frame)
        end

        # `ORDER BY` within the window: columns, or orderings such as `:age.desc`.
        # @return [AST::Over]
        def order(*exprs)
          raise ArgumentError, "order needs an expression" if exprs.empty?
          Over.new(function, partitions, orders + exprs, frame)
        end

        # `ROWS BETWEEN`, as a range of rows counted from the current one: negative before it, positive after, `0` the row itself, an open end unbounded.  `rows(..0)` is a running total, `rows(-1..1)` the row and its neighbours.
        # @param bounds [Range]
        # @return [AST::Over]
        def rows(bounds)
          Over.new(function, partitions, orders, framing(:rows, bounds))
        end

        # `RANGE BETWEEN`, with the bounds as {#rows} takes them.
        # @param bounds [Range]
        # @return [AST::Over]
        def range(bounds)
          Over.new(function, partitions, orders, framing(:range, bounds))
        end

        # @private
        def to_arel(table, model)
          window = Arel::Nodes::Window.new
          partitions.each { |expr| window.partition(to_arel_operand(expr, table, model)) }
          orders.each { |expr| window.order(to_arel_operand(expr, table, model)) }
          frame_arel(window) if frame

          # Not every aggregate can ride a window everywhere; the node itself
          # says where, once the adapter is known.
          function.check_window(model) if function.respond_to?(:check_window)

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
    end
  end
end
