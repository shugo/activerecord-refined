# frozen_string_literal: true

module ActiveRecord
  module Refined
    class Dialect
      # Microsoft SQL Server, reached through the sqlserver adapter over
      # tiny_tds.  Loaded only when a query is built for it.
      class SqlServer < Dialect
      end
    end
  end
end
