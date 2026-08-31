# frozen_string_literal: true

module ActiveRecord
  module Refined
    class Dialect
      # PostgreSQL, and the adapters that answer for the same server.
      class Postgresql < Dialect
        # @private
        FUNCTIONS = { log2: nil, rand: "RANDOM" }.freeze

        # PostgreSQL counts the bits of a bit string rather than a number, so
        # the argument is cast, to bit(64) for a negative to come back as the
        # MySQL family has it.
        def bit_count(expr, _model)
          AST::Function.new("BIT_COUNT", [AST::Cast.new(expr, "bit(64)")])
        end

        # PostgreSQL's XOR is #, where ^ is exponentiation.
        def bitwise_xor(left, right)
          Arel::Nodes::InfixOperation.new("#", left, right)
        end

        def json_path(document, _dollar_path, steps, json_value, _model)
          Arel::Nodes::InfixOperation.new(
            json_value ? :"#>" : :"#>>", document, Arel::Nodes.build_quoted(steps))
        end

        # An untyped JSON literal beside a jsonb operand coerces to jsonb, so
        # it passes as it is.
        def json_literal(json, _model)
          json
        end

        def json_contains(document, json, _model)
          Arel::Nodes::Contains.new(document, json)
        end

        # The ? operator, which a GIN index matches where jsonb_exists never is.
        def json_has_key(document, name, _path, _model)
          Arel::Nodes::InfixOperation.new(:"?", document, name)
        end

        def json_keys(document, model)
          sql = compile(document, model)
          Arel.sql("CASE WHEN jsonb_typeof(#{sql}) = 'object' " \
                   "THEN COALESCE((SELECT jsonb_agg(k) FROM jsonb_object_keys(#{sql}) k), " \
                   "CAST('[]' AS jsonb)) END")
        end

        # jsonb_set takes jsonb: an expression is turned into it, and a Ruby
        # value goes in as the JSON that says it -- '"x"' rather than 'x'.
        def json_set(document, steps, _dollar_path, value, expression, _model)
          set = expression ? Arel::Nodes::NamedFunction.new("to_jsonb", [expression]) :
                             Arel::Nodes.build_quoted(JSON.generate(value))
          Arel::Nodes::NamedFunction.new(
            "jsonb_set", [document, Arel::Nodes.build_quoted(steps), set])
        end

        # jsonb subtracts an array of keys; an untyped array literal would be
        # read as a single key, so it is cast to text[].
        def json_remove(document, _dollar_paths, steps, _model)
          keys = Arel::Nodes::NamedFunction.new(
            "CAST", [Arel::Nodes::As.new(
              Arel::Nodes.build_quoted(steps), Arel::Nodes::SqlLiteral.new("text[]"))])
          # Grouped because - binds tighter than #>.
          Arel::Nodes::InfixOperation.new(:-, Arel::Nodes::Grouping.new(document), keys)
        end

        def json_build(kind, keys, args, _model)
          Arel::Nodes::NamedFunction.new(
            kind == :array ? "jsonb_build_array" : "jsonb_build_object",
            json_build_body(kind, keys, args))
        end

        # jsonb_build_* takes typed arguments, so a JSON literal is cast; left
        # untyped it would be text, and land as a string.
        def json_build_argument(value, _model)
          Arel::Nodes::NamedFunction.new(
            "CAST", [Arel::Nodes::As.new(
              Arel::Nodes.build_quoted(JSON.generate(value)),
              Arel::Nodes::SqlLiteral.new("jsonb"))])
        end

        def json_aggregate_name(kind)
          kind == :arrayagg ? "jsonb_agg" : "jsonb_object_agg"
        end

        # STRING_AGG takes text and nothing else -- over an integer column it
        # is a function that does not exist -- so the operand is cast unless
        # the model says it is a string already.
        def string_agg(operand, separator, orders, string, model)
          unless string
            operand = Arel::Nodes::NamedFunction.new(
              "CAST", [Arel::Nodes::As.new(operand, Arel::Nodes::SqlLiteral.new("text"))])
          end
          string_agg_call("STRING_AGG", operand, separator, orders, model)
        end

        def grouping_supported?(_kind) = true

        # The names PostgreSQL knows, letters and digits and the _ . - its
        # catalog spells them with.  Wider than the bare families' plain
        # identifier because the name is quoted, so a hyphen is safe -- and
        # every ICU collation, en-US-x-icu among them, is spelled with one.
        # @private
        COLLATION_NAME = /\A[[:alnum:]_.-]+\z/

        # PostgreSQL's own collation names are case-sensitive and upper, "C",
        # "POSIX", so the name is quoted as an identifier to keep it from
        # folding to lower case.  The quoter is asked to spell it, as
        # excluded's VALUES(column) is on MySQL.
        def collate(operand, name, model)
          AST.check_name(name, COLLATION_NAME, "collation name")
          quoted = model.with_connection { |connection| connection.quote_column_name(name) }
          Arel::Nodes::InfixOperation.new(
            "COLLATE", operand, Arel::Nodes::SqlLiteral.new(quoted))
        end
      end
    end
  end
end
