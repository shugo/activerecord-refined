$LOAD_PATH.unshift(File.join(File.dirname(__FILE__), '..', 'lib'))

require 'active_record'
require 'activerecord-refined'

ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: ':memory:')
ActiveRecord::Migration.verbose = false

class Setup < ActiveRecord::Migration[8.1]
  def up
    create_table(:line_items) {|t| t.string :sku; t.string :category; t.integer :price; t.integer :quantity }
  end
end
Setup.new.up

class LineItem < ActiveRecord::Base
end

LineItem.create!(sku: 'A-1', category: 'tools',  price: 1200, quantity: 2)
LineItem.create!(sku: 'A-2', category: 'tools',  price: 300,  quantity: 5)
LineItem.create!(sku: 'B-1', category: 'paper',  price: 80,   quantity: 10)
LineItem.create!(sku: 'C-1', category: nil,      price: 50,   quantity: 1)

def show(title, relation, rows = nil)
  puts "--- #{title} ---"
  puts relation.to_sql
  puts rows.inspect unless rows.nil?
  puts
end

# 1. Arithmetic.  Ruby puts + - * / above the comparison operators, so an
#    expression groups the way it reads, without parentheses.
show('arithmetic in a condition',
  LineItem.where { :price * :quantity > 1000 },
  LineItem.where { :price * :quantity > 1000 }.pluck(:sku))

show('arithmetic in a select list, and aggregated',
  LineItem.select { [:sku, (:price * :quantity).as(:subtotal)] },
  LineItem.select { [:sku, (:price * :quantity).as(:subtotal)] }.
    map {|i| [i.sku, i.subtotal] })

show('an aggregate over an expression',
  LineItem.select { sum(:price * :quantity).as(:total) },
  LineItem.select { sum(:price * :quantity).as(:total) }.first.total)

# 2. Aggregates.  count takes :* for COUNT(*) and distinct: true for
#    COUNT(DISTINCT ...); the rest are sum, avg, min and max.
show('COUNT(*) and COUNT(DISTINCT ...)',
  LineItem.select { [count(:*).as(:rows), count(:category, distinct: true).as(:categories)] },
  LineItem.select { [count(:*).as(:rows), count(:category, distinct: true).as(:categories)] }.
    map {|i| [i.rows, i.categories] })

# 3. Functions.  Seven scalar ones have methods of their own; fn reaches
#    anything else, emitting the name as written.
show('built-in functions and the fn escape hatch',
  LineItem.
    where { length(:sku) == 3 }.
    select { [upper(:sku).as(:sku), coalesce(:category, 'unsorted').as(:category)] },
  LineItem.
    where { length(:sku) == 3 }.
    select { [upper(:sku).as(:sku), coalesce(:category, 'unsorted').as(:category)] }.
    map {|i| [i.sku, i.category] })

show('fn, for a function without a method of its own',
  LineItem.select { fn(:hex, :price).as(:hex_price) },
  LineItem.select { fn(:hex, :price).as(:hex_price) }.map(&:hex_price))

# 4. Ordering.  asc and desc take nulls_first / nulls_last.  MySQL has no
#    such syntax, but Arel emulates it there, so the order is the same
#    everywhere.
show('NULLS LAST',
  LineItem.order { [:category.asc.nulls_last, :sku.asc] },
  LineItem.order { [:category.asc.nulls_last, :sku.asc] }.pluck(:category, :sku))

# Aggregates and expressions can be ordered by, too.
show('grouped, aggregated and ordered by the aggregate',
  LineItem.
    group { :category }.
    having { count(:*) > 1 }.
    order { sum(:price * :quantity).desc }.
    select { [coalesce(:category, 'unsorted').as(:category), sum(:price * :quantity).as(:total)] },
  LineItem.
    group { :category }.
    having { count(:*) > 1 }.
    order { sum(:price * :quantity).desc }.
    select { [coalesce(:category, 'unsorted').as(:category), sum(:price * :quantity).as(:total)] }.
    map {|i| [i.category, i.total] })
