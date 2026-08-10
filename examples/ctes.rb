$LOAD_PATH.unshift(File.join(File.dirname(__FILE__), '..', 'lib'))

require 'active_record'
require 'activerecord-refined'

ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: ':memory:')
ActiveRecord::Migration.verbose = false

class Setup < ActiveRecord::Migration[8.1]
  def up
    create_table(:categories) {|t| t.string :name; t.integer :parent_id }
    create_table(:products)   {|t| t.string :name; t.integer :category_id; t.integer :price }
  end
end
Setup.new.up

class Category < ActiveRecord::Base
end

class Product < ActiveRecord::Base
end

electronics = Category.create!(name: 'electronics')
computers   = Category.create!(name: 'computers', parent_id: electronics.id)
laptops     = Category.create!(name: 'laptops', parent_id: computers.id)
groceries   = Category.create!(name: 'groceries')

Product.create!(name: 'ultrabook', category_id: laptops.id, price: 1200)
Product.create!(name: 'keyboard', category_id: computers.id, price: 80)
Product.create!(name: 'apple', category_id: groceries.id, price: 2)

# 1. Recursive CTE: every category below 'electronics', itself included.
#    The recursive member joins the CTE by name, so its ON clause is a block
#    rather than the string join Rails' own documentation reaches for.  `from`
#    then selects the CTE under the model's table name.
#
#    That alias is ActiveRecord's requirement rather than SQL's: by hand the
#    last line would be `SELECT * FROM tree`.  ActiveRecord keeps qualifying
#    columns with the model's table name, so without it `where` and `find_by`
#    look for a table the query does not have.  `count`, `order` and `select`
#    never qualify and would work either way, which makes it easy to miss.
subtree =
  Category.with_recursive(
    tree: [
      Category.where { :id == electronics.id },
      Category.joins(:tree) { :categories[:parent_id] == :tree[:id] },
    ]
  ).from(:tree, as: :categories)

puts '--- 1. Recursive CTE walking a category tree ---'
puts subtree.to_sql
puts subtree.order { :name }.pluck(:name).inspect
puts

# 2. The same CTE as a subquery: products anywhere under 'electronics'.
#    The outer query joins the CTE by name like any other table.
products_below =
  Product.with_recursive(
    tree: [
      Category.where { :id == electronics.id },
      Category.joins(:tree) { :categories[:parent_id] == :tree[:id] },
    ]
  ).joins(:tree) { :tree[:id] == :products[:category_id] }

puts '--- 2. Recursive CTE joined from the outer query ---'
puts products_below.to_sql
puts products_below.order { :name }.pluck(:name).inspect
puts

# 3. A plain CTE, named once and used twice: categories that hold something
#    expensive, and the count of products in each.
expensive =
  Category.with(pricey: Product.where { :price >= 100 }).
    joins(:pricey) { :pricey[:category_id] == :categories[:id] }.
    group { :categories[:id] }.
    select {
      [
        :categories[:name].as(:category),
        count(:pricey[:id]).as(:pricey_count),
        max(:pricey[:price]).as(:top_price),
      ]
    }

puts '--- 3. Plain CTE joined and aggregated ---'
puts expensive.to_sql
puts expensive.map {|c| [c.category, c.pricey_count, c.top_price] }.inspect
puts
