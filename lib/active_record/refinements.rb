module ActiveRecord
  module Refinements
    module WhereBlockSyntax
      refine Symbol do
        %i[== != =~ > >= < <=].each do |op|
          define_method(op) {|val| AST::Comparison.new(self, op, val) }
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
    end
  end
end
