# frozen_string_literal: true

module ActiveRecord
  module Refined
    class Dialect
      # Microsoft SQL Server, reached through the sqlserver adapter over
      # tiny_tds.  Loaded only when a query is built for it.
      class SqlServer < Dialect
        # LEN is its length; it has no printf FORMAT, no per-row random it
        # would spell RAND, no date_trunc, and none of the bit aggregates.
        FUNCTIONS = {
          char_length: "LEN",
          format: nil, rand: nil, date_trunc: nil,
          bit_and: nil, bit_or: nil, bit_xor: nil,
        }.freeze

        # No FILTER clause, so the aggregate node builds the CASE instead.
        def filter_supported? = false

        # No EXTRACT (it has DATEPART), and its datetime value functions take
        # no precision.
        def extract_supported? = false
        def datetime_precision_supported? = false
      end
    end
  end
end
