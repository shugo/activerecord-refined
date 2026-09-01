# frozen_string_literal: true

module ActiveRecord
  module Refined
    class Dialect
      # Microsoft SQL Server, reached through the sqlserver adapter over
      # tiny_tds.  Loaded only when a query is built for it.
      class SqlServer < Dialect
        # LEN is its length, CEILING its ceil, ATN2 its atan2, and LOG --
        # natural by default -- its ln; SUBSTRING insists on the length, so
        # substr wants all three arguments here.  It has no printf FORMAT, no
        # per-row random it would spell RAND, no date_trunc, no NOW or LOG2,
        # none of the bit aggregates, no MOD beside the % operator, and no
        # numeric TRUNC.  log is nil for a sharper reason: its LOG(x, base)
        # takes the arguments in the other order, so a rename would quietly
        # swap them.  Of the datetime value functions it has
        # CURRENT_TIMESTAMP alone: the other four are reserved words there
        # that stand for nothing.
        # @private
        FUNCTIONS = {
          char_length: "LEN", length: "LEN", substr: "SUBSTRING",
          ceil: "CEILING", atan2: "ATN2", ln: "LOG",
          mod: nil, trunc: nil, log: nil, log2: nil, now: nil,
          format: nil, rand: nil, date_trunc: nil,
          bit_and: nil, bit_or: nil, bit_xor: nil,
          current_date: nil, current_time: nil, localtime: nil, localtimestamp: nil,
        }.freeze

        # No FILTER clause, so the aggregate node builds the CASE instead.
        def filter_supported? = false

        # The operators are all here, the shifts included -- CI executes them.
        def bitwise_operators_supported? = true

        # ^ is XOR here as on MySQL, sparing the (a | b) - (a & b) the base
        # spells for SQLite's sake.
        def bitwise_xor(left, right)
          Arel::Nodes::BitwiseXor.new(left, right)
        end

        # No EXTRACT (it has DATEPART), and its datetime value functions take
        # no precision.
        def extract_supported? = false
        def datetime_precision_supported? = false

        # No boolean type: the column is a bit.  ISNULL reads a NULL as the
        # value the test is not looking for -- 0 for true?, 1 for false? --
        # so the plain form drops it and, being never NULL itself, the
        # negation is exactly NOT of the plain form, matching what ! builds.
        def truth_value(operand, value, negated, _model)
          equals = Arel::Nodes::Equality.new(
            Arel::Nodes::NamedFunction.new("ISNULL", [operand, value ? 0 : 1]),
            value ? 1 : 0)
          negated ? Arel::Nodes::Not.new(equals) : equals
        end

        # DATEADD(day, 3, x), the unit a bare keyword; a subtraction is a
        # negative amount, there being no DATESUB.
        def add_interval(date, amount, unit, subtract, _date_only)
          Arel::Nodes::NamedFunction.new(
            "DATEADD",
            [Arel::Nodes::SqlLiteral.new(unit.to_s),
             Arel::Nodes.build_quoted(subtract ? -amount : amount), date])
        end

        # STRING_AGG, with the WITHIN GROUP only when there is an order to
        # put in it.
        def string_agg(operand, separator, orders, _string, model)
          call = Arel::Nodes::NamedFunction.new(
            "STRING_AGG", [operand, Arel::Nodes.build_quoted(separator)])
          return call if orders.empty?
          Arel.sql("#{compile(call, model)} WITHIN GROUP " \
                   "(ORDER BY #{compile_list(orders, model)})")
        end

        def check_string_aggregate_window(model)
          raise NotImplementedError,
            "string_agg over a window has no equivalent on #{model.connection_db_config.adapter}"
        end

        # No JSON aggregates, so the SQL:2016 names the base keeps would
        # reach the server as functions it does not have.
        def json_aggregate_name(kind)
          raise NotImplementedError, "json_#{kind} has no equivalent on SQL Server"
        end

        # dig_text reads a scalar out with JSON_VALUE; dig keeps JSON with
        # JSON_QUERY, which returns a fragment and NULL for a scalar leaf.
        def json_path(document, dollar_path, _steps, json_value, _model)
          Arel::Nodes::NamedFunction.new(
            json_value ? "JSON_QUERY" : "JSON_VALUE",
            [document, Arel::Nodes.build_quoted(dollar_path)])
        end

        # JSON_PATH_EXISTS returns a bit, which the condition compares to 1.
        def json_has_key(document, _name, path, _model)
          Arel::Nodes::Equality.new(
            Arel::Nodes::NamedFunction.new("JSON_PATH_EXISTS", [document, path]),
            Arel::Nodes.build_quoted(1))
        end

        # A document, a boolean or a bare scalar written where JSON is wanted
        # rides in through JSON_QUERY as the JSON it spells.
        def json_argument(value, _model)
          Arel::Nodes::NamedFunction.new(
            "JSON_QUERY", [Arel::Nodes.build_quoted(JSON.generate(value))])
        end

        # bury: JSON_MODIFY sets a value at a path.
        def json_set(document, _steps, dollar_path, value, expression, model)
          Arel::Nodes::NamedFunction.new(
            "JSON_MODIFY",
            [document, Arel::Nodes.build_quoted(dollar_path),
             json_modify_value(value, expression, model)])
        end

        # except: JSON_MODIFY deletes a key when it sets it to a literal NULL,
        # one nested call per key.
        def json_remove(document, dollar_paths, _steps, _model)
          dollar_paths.reduce(document) do |doc, path|
            Arel::Nodes::NamedFunction.new(
              "JSON_MODIFY",
              [doc, Arel::Nodes.build_quoted(path), Arel::Nodes::SqlLiteral.new("NULL")])
          end
        end

        private
          # A document or array goes in through JSON_QUERY, which wants an
          # object or an array and refuses a scalar; a bare scalar is quoted.
          # A boolean, a null or a dug scalar is bury's business the tests skip.
          def json_modify_value(value, expression, model)
            return expression if expression
            return json_argument(value, model) if value.is_a?(::Hash) || value.is_a?(::Array)
            Arel::Nodes.build_quoted(value)
          end
      end
    end
  end
end
