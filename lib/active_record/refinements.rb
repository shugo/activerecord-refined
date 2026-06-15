module ActiveRecord
  module Refinements
    module WhereBlockSyntax
      refine Symbol do
        %i[== != =~ > >= < <=].each do |op|
          define_method(op) {|val| [self, op, val] }
        end
      end
    end

    module QueryMethods
      def where(opts = nil, *rest, &block)
        if block
          col, op, val = block.with_refinements(ActiveRecord::Refinements::WhereBlockSyntax).call
          arel_node = case op
          when :==
            table[col].eq val
          when :!=
            table[col].not_eq val
          when :=~
            table[col].matches val
          when :>
            table[col].gt val
          when :>=
            table[col].gteq val
          when :<
            table[col].lt val
          when :<=
            table[col].lteq val
          else
            raise "unexpected op: #{op}"
          end

          super(arel_node)
        else
          super
        end
      end
    end
  end
end
