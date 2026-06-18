module ActiveRecord
  module Refinements
    module BlockSyntax
      refine Symbol do
        %i[== != =~ !~ > >= < <=].each do |op|
          define_method(op) {|val| AST::Comparison.new(self, op, val) }
        end

        def null?
          AST::Comparison.new(self, :==, nil)
        end

        %i[count sum average maximum minimum].each do |func|
          define_method(func) { AST::Aggregate.new(self, func) }
        end

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
      AGGREGATE_FUNCTIONS = {
        count: :count, sum: :sum, avg: :average, min: :minimum, max: :maximum,
      }.freeze

      AGGREGATE_FUNCTIONS.each do |name, arel_func|
        define_method(name) {|column| AST::Aggregate.new(column, arel_func) }
      end

      SCALAR_FUNCTIONS = %i[upper lower length trim coalesce abs round].freeze

      SCALAR_FUNCTIONS.each do |name|
        define_method(name) {|*args| AST::Function.new(name.to_s.upcase, args) }
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

      def joins(*args, &block)
        if block
          super(build_join_node(args.first, Arel::Nodes::InnerJoin, &block))
        else
          super
        end
      end

      def left_outer_joins(*args, &block)
        if block
          joins(build_join_node(args.first, Arel::Nodes::OuterJoin, &block))
        else
          super
        end
      end

      private

      def evaluate_block(&block)
        refined = block.with_refinements(ActiveRecord::Refinements::BlockSyntax)
        BlockContext.new.instance_exec(&refined)
      end

      def to_arel_field(node)
        case node
        when AST::Node then node.to_arel(table)
        when Symbol then table[node]
        else node
        end
      end

      def build_join_node(target_table, join_class, &block)
        ast = evaluate_block(&block)
        join_class.new(
          Arel::Table.new(target_table),
          Arel::Nodes::On.new(ast.to_arel(table))
        )
      end
    end
  end
end
