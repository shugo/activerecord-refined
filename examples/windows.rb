# frozen_string_literal: true

$LOAD_PATH.unshift(File.join(File.dirname(__FILE__), "..", "lib"))

require "active_record"
require "activerecord-refined"

ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
ActiveRecord::Migration.verbose = false

class Setup < ActiveRecord::Migration[8.1]
  def up
    create_table(:sales) { |t| t.string :region; t.string :day; t.integer :amount }
  end
end
Setup.new.up

class Sale < ActiveRecord::Base
end

Sale.create!(region: "east", day: "2026-01-01", amount: 100)
Sale.create!(region: "east", day: "2026-01-02", amount: 40)
Sale.create!(region: "east", day: "2026-01-03", amount: 60)
Sale.create!(region: "west", day: "2026-01-01", amount: 20)
Sale.create!(region: "west", day: "2026-01-02", amount: 90)

def show(title, relation, rows = nil)
  puts "--- #{title} ---"
  puts relation.to_sql
  puts rows.inspect unless rows.nil?
  puts
end

# 1. A window on an aggregate.  over turns an aggregate into a window
#    function: the rows stay, and the aggregate is worked out over the window
#    beside each one.  Without partition or order the window is every row.
show("the total beside every row",
  Sale.select { [:region, :amount, sum(:amount).over.as(:total)] },
  Sale.select { [:region, :amount, sum(:amount).over.as(:total)] }.
    map { |s| [s.region, s.amount, s.total] })

# partition divides the rows into groups the window is worked out within.
totals = -> {
  Sale.select { [:region, :amount, sum(:amount).over.partition(:region).as(:region_total)] }
}
show("a total per region, still row by row",
  totals.call,
  totals.call.map { |s| [s.region, s.amount, s.region_total] })

# 2. Frames.  With an order, the window can be cut down to a range of rows
#    around the current one.  A Range of integers is what says which: 0 is the
#    current row, a beginless range reaches back to the start of the
#    partition, an endless one forward to its end.
running = -> {
  Sale.select {
    [:region, :day, :amount,
     sum(:amount).over.partition(:region).order(:day).rows(..0).as(:running)]
  }
}
show("a running total within each region",
  running.call,
  running.call.map { |s| [s.region, s.day, s.amount, s.running] })

# 3. The functions that say nothing without a window.  row_number, rank and
#    dense_rank number the rows of each partition; lag and lead reach the row
#    before and after.  Each raises rather than reaching the database if over
#    never arrives.
ranked = -> {
  Sale.select {
    [:region, :amount,
     row_number.over.partition(:region).order(:amount.desc).as(:place),
     lag(:amount).over.partition(:region).order(:day).as(:previous)]
  }
}
show("the place within the region, and the day before",
  ranked.call,
  ranked.call.map { |s| [s.region, s.amount, s.place, s.previous] })

begin
  Sale.select { row_number }
rescue ArgumentError => e
  puts "--- a window function needs a window ---"
  puts "  #{e.message}"
  puts
end

# 4. The top row of each group, which is what a window is most often for: the
#    numbering goes in a subquery, since a window function cannot be used in
#    the WHERE of the query that computes it.
numbered = Sale.select {
  [:region, :day, :amount, row_number.over.partition(:region).order(:amount.desc).as(:place)]
}
# The subquery is named after the model's own table because Active Record goes
# on qualifying columns with that name, so where has to find it there.
show("the biggest sale of each region",
  Sale.from(numbered, :sales).where { :place == 1 },
  Sale.from(numbered, :sales).where { :place == 1 }.
    map { |s| [s.region, s.day, s.amount] })
