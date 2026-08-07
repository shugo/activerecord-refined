$LOAD_PATH.unshift(File.join(File.dirname(__FILE__), '..', 'lib'))

require 'active_record'
require 'activerecord-refined'

ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: ':memory:')
ActiveRecord::Migration.verbose = false

class Setup < ActiveRecord::Migration[8.1]
  def up
    create_table(:authors) {|t| t.string :name; t.integer :age; t.string :country }
    create_table(:posts)   {|t| t.string :title; t.integer :author_id; t.integer :likes; t.boolean :published }
    create_table(:comments){|t| t.string :body; t.integer :post_id; t.integer :score }
  end
end
Setup.new.up

class Author < ActiveRecord::Base
  has_many :posts
end

class Post < ActiveRecord::Base
  belongs_to :author
  has_many :comments
end

class Comment < ActiveRecord::Base
  belongs_to :post
end

# 1. Post statistics per author
#    JOIN + GROUP BY + aggregate functions + AS + HAVING + ORDER BY
query1 =
  Author.
    joins(:posts) { :posts[:author_id] == :authors[:id] }.
    where { :posts[:published] == true }.
    group { :authors[:id] }.
    having { count(:posts[:id]) > 1 }.
    order { count(:posts[:id]).desc }.
    select {
      [
        upper(:authors[:name]).as(:author),
        count(:posts[:id]).as(:post_count),
        avg(:posts[:likes]).as(:avg_likes),
        max(:posts[:likes]).as(:top_likes),
      ]
    }

puts "--- 1. Per-author post stats (GROUP BY / aggregates / AS / HAVING / ORDER BY) ---"
puts query1.to_sql
puts

# 2. Author count per country (NULL is folded into 'unknown')
#    coalesce function + GROUP BY + aggregates + multiple ORDER BY
query2 =
  Author.
    group { coalesce(:country, 'unknown') }.
    order { [count(:id).desc, coalesce(:country, 'unknown').asc] }.
    select {
      [
        coalesce(:country, 'unknown').as(:country),
        count(:id).as(:author_count),
        avg(:age).as(:avg_age),
      ]
    }

puts "--- 2. Authors per country (coalesce / GROUP BY / multi ORDER BY) ---"
puts query2.to_sql
puts

# 3. Aggregate comment scores across a multi-level JOIN
#    authors -> posts -> comments, compound WHERE + GROUP BY + HAVING + ORDER BY
query3 =
  Author.
    joins(:posts) { :posts[:author_id] == :authors[:id] }.
    joins(:comments) { :comments[:post_id] == :posts[:id] }.
    where { !:posts[:title].include?('draft') & (:comments[:score] >= 0) }.
    group { :authors[:id] }.
    having { sum(:comments[:score]) > 10 }.
    order { sum(:comments[:score]).desc }.
    select {
      [
        :authors[:name].as(:author),
        count(:comments[:id]).as(:comment_count),
        sum(:comments[:score]).as(:total_score),
      ]
    }

puts "--- 3. Comment score aggregation across multi-table JOIN ---"
puts query3.to_sql
puts
