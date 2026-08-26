# frozen_string_literal: true

module ActiveRecord
  module Refined
    class Dialect
      # Oracle, reached through oracle_enhanced.  Loaded only when a query is
      # built for it.
      class Oracle < Dialect
        # Oracle keeps scalars and structures in different functions: JSON_VALUE
        # reads a scalar out as text, JSON_QUERY a fragment as JSON.  dig keeps
        # JSON, so it takes JSON_QUERY with 23ai's ALLOW SCALARS, which returns
        # a scalar leaf as itself rather than wrapping or refusing it.
        def json_path(document, dollar_path, _steps, json_value, model)
          unless json_value
            return Arel::Nodes::NamedFunction.new(
              "JSON_VALUE", [document, Arel::Nodes.build_quoted(dollar_path)])
          end
          Arel.sql(
            "JSON_QUERY(#{compile(document, model)}, " \
            "#{quote(dollar_path, model)} RETURNING VARCHAR2(4000) ALLOW SCALARS " \
            "NULL ON EMPTY)")
        end

        def json_has_key(document, _name, path, _model)
          Arel::Nodes::NamedFunction.new("JSON_EXISTS", [document, path])
        end

        # No JSON_KEYS, and the keys reach only through a JSON_TABLE unnest not
        # written yet.
        def json_keys(_document, model)
          raise NotImplementedError,
            "keys has no equivalent on #{model.connection_db_config.adapter}"
        end
      end
    end
  end
end
