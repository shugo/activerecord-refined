# frozen_string_literal: true

$LOAD_PATH.unshift(File.join(File.dirname(__FILE__), "..", "lib"))

require "active_record"
require "activerecord-refined"

ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
ActiveRecord::Migration.verbose = false

class Setup < ActiveRecord::Migration[8.1]
  def up
    create_table(:categories) { |t| t.string :name; t.integer :parent_id }
    create_table(:products)   { |t| t.string :name; t.integer :category_id; t.integer :price }
  end
end
Setup.new.up

class Category < ActiveRecord::Base
end

class Product < ActiveRecord::Base
end

electronics = Category.create!(name: "electronics")
computers   = Category.create!(name: "computers", parent_id: electronics.id)
laptops     = Category.create!(name: "laptops", parent_id: computers.id)
groceries   = Category.create!(name: "groceries")

Product.create!(name: "ultrabook", category_id: laptops.id, price: 1200)
Product.create!(name: "keyboard", category_id: computers.id, price: 80)
Product.create!(name: "apple", category_id: groceries.id, price: 2)

# 1. Recursive CTE: every category below 'electronics', itself included.
#    The recursive member joins the CTE by name, so its ON clause is a block
#    rather than the string join Rails' own documentation reaches for.
#    `from_cte` then selects the CTE under the model's table name.
#
#    That alias is Active Record's requirement rather than SQL's: by hand the
#    last line would be `SELECT * FROM tree`.  Active Record keeps qualifying
#    columns with the model's table name, so without it `where` and `find_by`
#    look for a table the query does not have.  `count`, `order` and `select`
#    never qualify and would work either way, which makes it easy to miss.
subtree =
  Category.with_recursive(
    tree: [
      Category.where { :id == electronics.id },
      Category.joins(:tree) { :categories[:parent_id] == :tree[:id] },
    ]
  ).from_cte(:tree)

puts "--- 1. Recursive CTE walking a category tree ---"
puts subtree.to_sql
puts subtree.order { :name }.pluck(:name).inspect
puts

# 2. One walk over every tree, carrying down where each row started and how
#    far it has come.  Which tree is wanted is then an ordinary `where`, asked
#    afterwards, so the CTE is not rebuilt for each root.  0 is a value rather
#    than SQL: at the top of a select list a bare string would be SQL, so
#    numbers say `.as` directly and anything else says `value(...).as`.
forest =
  Category.with_recursive(
    tree: [
      Category.where { :parent_id.null? }.
        select { [:id, :name, :parent_id, :id.as(:root_id), 0.as(:depth)] },
      Category.joins(:tree) { :categories[:parent_id] == :tree[:id] }.
        select { [:id, :name, :parent_id,
                  :tree[:root_id], (:tree[:depth] + 1).as(:depth)] },
    ]
  ).from_cte(:tree).order { [:depth, :id] }

puts "--- 2. Recursive CTE carrying the root and the depth down ---"
puts forest.to_sql
puts forest.map { |c| [c.name, c.root_id, c.depth] }.inspect

# The alias from_cte puts on the CTE is what lets this `where` qualify
# root_id; without it the column would be looked for in a table the query no
# longer has.
puts forest.where { :root_id == electronics.id }.map { |c| [c.name, c.depth] }.inspect
puts

# 3. The same CTE as a subquery: products anywhere under 'electronics'.
#    The outer query joins the CTE by name like any other table.
products_below =
  Product.with_recursive(
    tree: [
      Category.where { :id == electronics.id },
      Category.joins(:tree) { :categories[:parent_id] == :tree[:id] },
    ]
  ).joins(:tree) { :tree[:id] == :products[:category_id] }

puts "--- 3. Recursive CTE joined from the outer query ---"
puts products_below.to_sql
puts products_below.order { :name }.pluck(:name).inspect
puts

# 4. A plain CTE, named once and used twice: categories that hold something
#    expensive, and the count of products in each.
expensive =
  Category.with(pricey: Product.where { :price >= 100 }).
    joins(:pricey) { :pricey[:category_id] == :categories[:id] }.
    group { :id }.
    select {
      [
        :name.as(:category),
        count(:pricey[:id]).as(:pricey_count),
        max(:pricey[:price]).as(:top_price),
      ]
    }

puts "--- 4. Plain CTE joined and aggregated ---"
puts expensive.to_sql
puts expensive.map { |c| [c.category, c.pricey_count, c.top_price] }.inspect
puts
