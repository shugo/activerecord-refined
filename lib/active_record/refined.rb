module ActiveRecord
  module Refined
    module BlockSyntax
      refine Symbol do
        import_methods AST::Predications
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
      AGGREGATE_FUNCTIONS = {
        sum: :sum, avg: :average, min: :minimum, max: :maximum,
      }.freeze

      AGGREGATE_FUNCTIONS.each do |name, arel_func|
        define_method(name) {|column| AST::Aggregate.new(column, arel_func) }
      end

      def count(column, distinct: false)
        AST::Aggregate.new(column, :count, distinct: distinct)
      end

      SCALAR_FUNCTIONS = %i[upper lower length trim coalesce abs round].freeze

      SCALAR_FUNCTIONS.each do |name|
        define_method(name) {|*args| AST::Function.new(name.to_s.upcase, args) }
      end

      # Escape hatch for functions without a method of their own.  The name is
      # emitted as written, so a case-sensitive one can be spelled exactly.
      def fn(name, *args)
        AST::Function.new(name.to_s, args)
      end

      def exists?(relation)
        AST::Exists.new(relation)
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
        refined_block = block.refined(ActiveRecord::Refined::BlockSyntax)
        BlockContext.new.instance_exec(&refined_block)
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
