module ActiveRecord
  module Refinements
    module WhereBlockSyntax
      refine Symbol do
        %i[== != =~ > >= < <=].each do |op|
          define_method(op) {|val| AST::Comparison.new(self, op, val) }
        end

        %i[name id type].each do |method_name|
          define_method(method_name) { AST::Column.new(self, method_name) }
        end

        def method_missing(method_name, *args, &block)
          if args.empty? && !block
            AST::Column.new(self, method_name)
          else
            super
          end
        end

        def respond_to_missing?(method_name, include_private = false)
          true
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
