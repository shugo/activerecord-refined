# frozen_string_literal: true

module ActiveRecord
  module Refined
    class Dialect
      # Oracle, reached through oracle_enhanced.  Loaded only when a query is
      # built for it.
      class Oracle < Dialect
      end
    end
  end
end
