# frozen_string_literal: true

module ActiveRecord
  module Refined
    class Dialect
      # SQLite: the fewest of the extras, and a JSON path through its own
      # operators.
      class Sqlite < Dialect
        def datetime_precision_supported? = false
        def extract_supported? = false
        def quantifiers_supported? = false

        def check_lateral(model)
          raise NotImplementedError,
            "a lateral join has no equivalent on #{model.connection_db_config.adapter}"
        end
      end
    end
  end
end
