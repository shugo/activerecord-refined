# frozen_string_literal: true

module ActiveRecord
  module Refined
    class Dialect
      # MariaDB, which answers to the MySQL adapter but has no JSON type and no
      # LATERAL.
      class Mariadb < MysqlCompat
        def check_lateral(_model)
          raise NotImplementedError, "a lateral join has no equivalent on MariaDB"
        end
      end
    end
  end
end
