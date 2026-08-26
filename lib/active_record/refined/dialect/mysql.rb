# frozen_string_literal: true

module ActiveRecord
  module Refined
    class Dialect
      # MySQL proper, which has a JSON type of its own where MariaDB has only
      # the text.
      class Mysql < MysqlCompat
        # MySQL has a JSON type, so a Ruby value is cast to it; a bare string
        # beside JSON would be a JSON string, outranking every number.
        def json_literal(json, _model)
          Arel::Nodes::NamedFunction.new(
            "CAST", [Arel::Nodes::As.new(json, Arel::Nodes::SqlLiteral.new("JSON"))])
        end
      end
    end
  end
end
