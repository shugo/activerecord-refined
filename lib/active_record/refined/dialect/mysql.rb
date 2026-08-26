# frozen_string_literal: true

module ActiveRecord
  module Refined
    class Dialect
      # MySQL proper, which has a JSON type of its own where MariaDB has only
      # the text.
      class Mysql < MysqlCompat
      end
    end
  end
end
