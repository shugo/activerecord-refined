# What the sandbox adds to the vendored wasmify-rails adapter beside this
# file.  Requiring this is what makes the pglite adapter usable; the vendored
# file is never required on its own.
#
# The JS side is pglite-bridge.mjs, which puts an object answering to
# create_interface on globalThis under the name the adapter looks for.

require 'active_record/connection_adapters/pglite_adapter'

module PG
  class Connection
    # The stub quotes an identifier only where it would otherwise be read
    # wrongly; the pg gem quotes every one, which is not the same thing at
    # all, since PostgreSQL folds an unquoted identifier to lower case.  An
    # alias asked for as Author came back as author -- and a name that comes
    # back changed is a column the block cannot read the row by.
    def self.quote_ident(name)
      '"' + name.to_s.gsub('"', '""') + '"'
    end
  end

  # PostgreSQL::OID::Array hands the literal to the pg gem to write and read,
  # so an array column needs these two even though every other type is cast by
  # Active Record itself.  Only the text format is here: that is all the adapter
  # ever asks for.
  module TextEncoder
    class Array
      def initialize(name: nil, delimiter: ',')
        @delimiter = delimiter
      end

      def encode(values)
        '{' + values.map {|value| element(value) }.join(@delimiter) + '}'
      end

      private

      # An element is quoted when leaving it bare would say something else: an
      # empty string would be nothing at all, the word NULL would be the null
      # element, and a brace, a quote or the delimiter would end it early.
      def element(value)
        case value
        when nil then 'NULL'
        when ::Array then encode(value)
        else
          string = value.to_s
          if string.empty? || string.casecmp('NULL').zero? ||
             string.match?(/[{}",\\[:space:]]/) || string.include?(@delimiter)
            '"' + string.gsub(/(["\\])/, '\\\\\1') + '"'
          else
            string
          end
        end
      end
    end
  end

  module TextDecoder
    class Array
      def initialize(name: nil, delimiter: ',')
        @delimiter = delimiter
      end

      # OID::Array freezes what it is given, so where in the string the
      # reading has got to cannot be kept here.
      def decode(string)
        Reader.new(string, @delimiter).read
      end

      class Reader
        def initialize(string, delimiter)
          @s = string
          @delimiter = delimiter
          @i = 0
        end

        def read
          skip_dimensions
          array
        end

        private

        # A literal may carry the range of its subscripts, as in [1:3]={a,b,c}.
        # What it says is of no interest here; where it ends is.
        def skip_dimensions
          return unless @s[@i] == '['
          @i = @s.index('=', @i).to_i + 1
        end

        def array
          raise TypeError, "not an array literal: #{@s.inspect}" unless @s[@i] == '{'
          @i += 1
          values = []
          return values.tap { @i += 1 } if @s[@i] == '}'

          loop do
            values << (@s[@i] == '{' ? array : element)
            case @s[@i]
            when @delimiter
              @i += 1
            when '}'
              @i += 1
              break
            else
              raise TypeError, "not an array literal: #{@s.inspect}"
            end
          end
          values
        end

        def element
          return quoted_element if @s[@i] == '"'

          from = @i
          @i += 1 until @s[@i].nil? || @s[@i] == @delimiter || @s[@i] == '}'
          raw = @s[from...@i]
          # Only an unquoted NULL is the null element; "NULL" is the string.
          raw.casecmp('NULL').zero? ? nil : raw
        end

        def quoted_element
          @i += 1
          out = +''
          while (c = @s[@i])
            break if c == '"'
            if c == '\\'
              @i += 1
              out << @s[@i]
            else
              out << c
            end
            @i += 1
          end
          @i += 1
          out
        end
      end
    end
  end
end

module ActiveRecord
  module ConnectionAdapters
    # The vendored adapter maps a handful of OIDs by hand and knows nothing of
    # the array types, so an array column's value would reach PGlite as a JS
    # array and come back as PostgreSQL's literal for one.  OID::Array is what
    # writes and reads that literal.
    module PGliteArrayTypes
      ARRAY_OIDS = {
        1000 => ActiveRecord::Type::Boolean,
        1005 => ActiveRecord::Type::Integer,
        1007 => ActiveRecord::Type::Integer,
        1009 => ActiveRecord::Type::String,
        1015 => ActiveRecord::Type::String,
        1016 => ActiveRecord::Type::Integer,
        1021 => ActiveRecord::Type::Float,
        1022 => ActiveRecord::Type::Float,
      }.freeze

      def get_oid_type(oid, fmod, column_name, sql_type = '')
        subtype = ARRAY_OIDS[oid.to_i]
        return super unless subtype
        type = PostgreSQL::OID::Array.new(subtype.new, ',')
        @type_map.register_type(oid.to_i, type)
        type
      end
    end

    # PostgreSQLAdapter reads the SQLSTATE off the pg gem's result to decide
    # which Active Record error a failure is, and hands back the exception
    # untouched when there is none to read -- which here is always, since the
    # JS side has only a message.  Everything the database rejects is a
    # StatementInvalid instead, which is what the page is written to catch.
    module PGliteErrors
      def translate_exception(exception, message:, sql:, binds:)
        return super if exception.respond_to?(:result)
        ActiveRecord::StatementInvalid.new(
          message, sql: sql, binds: binds, connection_pool: @pool)
      end
    end

    PGliteAdapter.prepend(PGliteArrayTypes)
    PGliteAdapter.prepend(PGliteErrors)
  end
end

# Rails 7.2 and later resolve an adapter through this registry; the
# *_connection hook the vendored adapter defines is no longer looked at.
ActiveRecord::ConnectionAdapters.register(
  'pglite',
  'ActiveRecord::ConnectionAdapters::PGliteAdapter',
  'active_record/connection_adapters/pglite_adapter')
