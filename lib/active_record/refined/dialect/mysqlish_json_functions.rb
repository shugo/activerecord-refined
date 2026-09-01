# frozen_string_literal: true

module ActiveRecord
  module Refined
    class Dialect
      # The JSON editing and building functions MySQL and SQLite spell
      # alike: JSON_SET and JSON_REMOVE over a $ path, and JSON_ARRAY and
      # JSON_OBJECT with each key alternating with its value.  The spellings
      # are MySQL's, which SQLite's json1 took over, and standard in
      # neither sense of the word -- SQL:2016 gives JSON_OBJECT a KEY k
      # VALUE v syntax and has no editing functions at all -- so they live
      # here as a family likeness for the two to include, not in the base
      # as a default for everyone.
      module MysqlishJsonFunctions
        def json_set(document, _steps, dollar_path, value, expression, model)
          Arel::Nodes::NamedFunction.new(
            "JSON_SET",
            [document, Arel::Nodes.build_quoted(dollar_path),
             json_set_value(value, expression, model)])
        end

        def json_remove(document, dollar_paths, _steps, _model)
          Arel::Nodes::NamedFunction.new(
            "JSON_REMOVE",
            [document, *dollar_paths.map { |path| Arel::Nodes.build_quoted(path) }])
        end

        def json_build(kind, keys, args, _model)
          Arel::Nodes::NamedFunction.new(
            kind == :array ? "JSON_ARRAY" : "JSON_OBJECT",
            json_build_body(kind, keys, args))
        end

        private
          # The value beside a path in JSON_SET: an expression as it is, a
          # document or boolean as JSON, a bare scalar quoted.
          def json_set_value(value, expression, model)
            return expression if expression
            return Arel::Nodes.build_quoted(value) unless json_document_value?(value)
            json_argument(value, model)
          end
      end
    end
  end
end
