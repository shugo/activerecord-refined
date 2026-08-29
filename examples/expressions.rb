# frozen_string_literal: true

$LOAD_PATH.unshift(File.join(File.dirname(__FILE__), "..", "lib"))

require "active_record"
require "activerecord-refined"

ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
ActiveRecord::Migration.verbose = false

class Setup < ActiveRecord::Migration[8.1]
  def up
    create_table(:line_items) do |t|
      t.string :sku
      t.string :category
      t.integer :price
      t.integer :quantity
      t.integer :flags
      t.date :ordered_on
    end
  end
end
Setup.new.up

class LineItem < ActiveRecord::Base
end

LineItem.create!(sku: "A-1", category: "tools",  price: 1200, quantity: 2,  flags: 12,
                 ordered_on: Date.new(2026, 1, 5))
LineItem.create!(sku: "A-2", category: "tools",  price: 300,  quantity: 5,  flags: 10,
                 ordered_on: Date.new(2026, 1, 20))
LineItem.create!(sku: "B-1", category: "paper",  price: 80,   quantity: 10, flags: 3,
                 ordered_on: Date.new(2026, 2, 3))
LineItem.create!(sku: "B-2", category: "paper",  price: 80,   quantity: 10, flags: 3,
                 ordered_on: Date.new(2026, 2, 3))
LineItem.create!(sku: "C-1", category: nil,      price: 50,   quantity: 1,  flags: 4,
                 ordered_on: Date.new(2026, 2, 14))

def show(title, relation, rows = nil)
  puts "--- #{title} ---"
  puts relation.to_sql
  puts rows.inspect unless rows.nil?
  puts
end

# 1. Arithmetic.  Ruby puts + - * / above the comparison operators, so an
#    expression groups the way it reads, without parentheses.
show("arithmetic in a condition",
  LineItem.where { :price * :quantity > 1000 },
  LineItem.where { :price * :quantity > 1000 }.pluck(:sku))

show("arithmetic in a select list, and aggregated",
  LineItem.select { [:sku, (:price * :quantity).as(:subtotal)] },
  LineItem.select { [:sku, (:price * :quantity).as(:subtotal)] }.
    map { |i| [i.sku, i.subtotal] })

show("an aggregate over an expression",
  LineItem.select { sum(:price * :quantity).as(:total) },
  LineItem.select { sum(:price * :quantity).as(:total) }.first.total)

# The number may stand on the left; only a column or an expression on the
# right builds a query, so Ruby's own arithmetic is untouched.  BigDecimal
# is a number here too -- what a decimal column's values are.
show("the number on the left, and a BigDecimal",
  LineItem.select { [:sku, (12 - :quantity).as(:to_the_dozen)] },
  LineItem.select { [:sku, (12 - :quantity).as(:to_the_dozen)] }.
    map { |i| [i.sku, i.to_the_dozen] })

show("a tax through BigDecimal, exact on the wire",
  LineItem.select { [:sku, (BigDecimal("1.1") * :price).as(:taxed)] },
  LineItem.select { [:sku, (BigDecimal("1.1") * :price).as(:taxed)] }.
    map { |i| [i.sku, i.taxed] })

# A duration moves a date.  Each adapter spells the move its own way; SQLite
# has date() and datetime(), and a date column keeps being a date.
show("a date moved by a duration",
  LineItem.where { :ordered_on + 30.days < Date.new(2026, 2, 10) },
  LineItem.where { :ordered_on + 30.days < Date.new(2026, 2, 10) }.pluck(:sku))

show("a due date a month on",
  LineItem.select { [:sku, (:ordered_on + 1.month).as(:due_on)] },
  LineItem.select { [:sku, (:ordered_on + 1.month).as(:due_on)] }.
    map { |i| [i.sku, i.due_on] })

# The bitwise operators.  & and | are AND and OR between conditions, which is
# what leaves them free here.  Each expression parenthesises itself, so the
# grouping is Ruby's rather than the adapter's.
show("a bit test in a condition",
  LineItem.where { :flags & 4 > 0 },
  LineItem.where { :flags & 4 > 0 }.pluck(:sku))

# XOR is the one the three adapters do not share.  SQLite has none, so it gets
# the two operations XOR is made of; PostgreSQL would say #, MySQL ^.
show("xor, spelled the way the adapter spells it",
  LineItem.select { [:sku, (:flags ^ 10).as(:xored)] },
  LineItem.select { [:sku, (:flags ^ 10).as(:xored)] }.map { |i| [i.sku, i.xored] })

# A condition cannot be an operand, and neither can a boolean column: two of
# the three adapters would quietly answer as AND does and the third has no
# such operator, so the block refuses instead.
begin
  LineItem.where { :flags & (:price == 1) }
rescue ArgumentError => e
  puts "--- a condition is not an operand of & ---"
  puts "  #{e.message}"
  puts
end

# 2. Aggregates.  count takes :* for COUNT(*) and distinct: true for
#    COUNT(DISTINCT ...), which sum and avg take too; the rest are min and max.
show("COUNT(*) and COUNT(DISTINCT ...)",
  LineItem.select { [count(:*).as(:rows), count(:category, distinct: true).as(:categories)] },
  LineItem.select { [count(:*).as(:rows), count(:category, distinct: true).as(:categories)] }.
    map { |i| [i.rows, i.categories] })

show("SUM(DISTINCT ...), each quantity counted once",
  LineItem.select { [sum(:quantity).as(:all), sum(:quantity, distinct: true).as(:once)] },
  LineItem.select { [sum(:quantity).as(:all), sum(:quantity, distinct: true).as(:once)] }.
    map { |i| [i.all, i.once] })

# filter takes the aggregate over the rows a condition holds for.  SQLite and
# PostgreSQL have the FILTER clause; MySQL gets the CASE that means the same,
# since an aggregate passes over the NULL a missed row leaves.
show("two aggregates over different rows of the same query",
  LineItem.select {
    [count(:*).as(:all), sum(:price).filter { :category == "tools" }.as(:tools)]
  },
  LineItem.select {
    [count(:*).as(:all), sum(:price).filter { :category == "tools" }.as(:tools)]
  }.map { |i| [i.all, i.tools] })

# CASE has two shapes: an operand to compare each when against, or a condition
# on every when.  case is a Ruby keyword, so the method behind both is only
# reachable through the receiver -- self.case -- and each shape has a shorthand
# that does not need it.
show("a CASE with an operand, through the shorthand",
  LineItem.select { [:sku, :category.when("tools").then("hardware").else("other").as(:kind)] },
  LineItem.select { [:sku, :category.when("tools").then("hardware").else("other").as(:kind)] }.
    map { |i| [i.sku, i.kind] })

show("a CASE where each when carries its own condition",
  LineItem.select {
    [:sku, case_when { :price >= 1000 }.then("dear").when { :price >= 100 }.
      then("middling").else("cheap").as(:band)]
  },
  LineItem.select {
    [:sku, case_when { :price >= 1000 }.then("dear").when { :price >= 100 }.
      then("middling").else("cheap").as(:band)]
  }.map { |i| [i.sku, i.band] })

# It is an expression like any other, so it goes inside an aggregate too.
show("counting with a CASE",
  LineItem.select { sum(case_when { :price >= 100 }.then(1).else(0)).as(:dear_ones) },
  LineItem.select { sum(case_when { :price >= 100 }.then(1).else(0)).as(:dear_ones) }.
    map { |i| i.dear_ones })

# 3. Functions.  Seven scalar ones have methods of their own; fn reaches
#    anything else, emitting the name as written.
show("built-in functions and the fn escape hatch",
  LineItem.
    where { length(:sku) == 3 }.
    select { [upper(:sku).as(:sku), coalesce(:category, "unsorted").as(:category)] },
  LineItem.
    where { length(:sku) == 3 }.
    select { [upper(:sku).as(:sku), coalesce(:category, "unsorted").as(:category)] }.
    map { |i| [i.sku, i.category] })

show("fn, for a function without a method of its own",
  LineItem.select { fn(:hex, :price).as(:hex_price) },
  LineItem.select { fn(:hex, :price).as(:hex_price) }.map(&:hex_price))

# op is the same for operators: the operator is emitted as written --
# checked against the operator characters -- and both sides are quoted
# values, columns or expressions.  What it gives compares like any other
# expression.
show("op, for an operator without a method of its own",
  LineItem.where { op("%", :quantity, 2) == 1 },
  LineItem.where { op("%", :quantity, 2) == 1 }.pluck(:sku))

# sql is the last resort, and the one way a string means SQL inside a block:
# a bare string is refused there, and ? and :name placeholders take quoted
# values.  What it gives is parenthesized wherever it stands as an operand.
show("sql, for what neither fn nor op can spell",
  LineItem.where { sql("price % ?", 100) == 0 },
  LineItem.where { sql("price % ?", 100) == 0 }.pluck(:sku))

# A string sent `as` is a value, like a number.
show("a string literal in a select list",
  LineItem.select { [:sku, "listed".as(:state)] },
  LineItem.select { [:sku, "listed".as(:state)] }.map { |i| [i.sku, i.state] })

# 4. Ordering.  asc and desc take nulls_first / nulls_last.  MySQL has no
#    such syntax, but Arel emulates it there, so the order is the same
#    everywhere.
show("NULLS LAST",
  LineItem.order { [:category.asc.nulls_last, :sku.asc] },
  LineItem.order { [:category.asc.nulls_last, :sku.asc] }.pluck(:category, :sku))

# collate names a collation -- how the database compares and orders strings --
# and gives back an expression, so it carries into a comparison or an order.
# The names are the database's own; nocase is SQLite's case-insensitive one.
show("a case-insensitive comparison under a collation",
  LineItem.where { :category.collate(:nocase) == "TOOLS" },
  LineItem.where { :category.collate(:nocase) == "TOOLS" }.pluck(:sku))

# Aggregates and expressions can be ordered by, too.
show("grouped, aggregated and ordered by the aggregate",
  LineItem.
    group { :category }.
    having { count(:*) > 1 }.
    order { sum(:price * :quantity).desc }.
    select { [coalesce(:category, "unsorted").as(:category), sum(:price * :quantity).as(:total)] },
  LineItem.
    group { :category }.
    having { count(:*) > 1 }.
    order { sum(:price * :quantity).desc }.
    select { [coalesce(:category, "unsorted").as(:category), sum(:price * :quantity).as(:total)] }.
    map { |i| [i.category, i.total] })
