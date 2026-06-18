module ActiveRecord
  module Refinements
    module WhereBlockSyntax
      refine Symbol do
        %i[== != =~ !~ > >= < <=].each do |op|
          define_method(op) {|val| AST::Comparison.new(self, op, val) }
        end

        def [](column_name)
          AST::Column.new(self, column_name)
        end
      end
    end

    module QueryMethods
      def where(opts = nil, *rest, &block)
        if block
          ast = block.with_refinements(ActiveRecord::Refinements::WhereBlockSyntax).call
          super(ast.to_arel(table))
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

      def build_join_node(target_table, join_class, &block)
        ast = block.with_refinements(ActiveRecord::Refinements::WhereBlockSyntax).call
        join_class.new(
          Arel::Table.new(target_table),
          Arel::Nodes::On.new(ast.to_arel(table))
        )
      end
    end
  end
end
