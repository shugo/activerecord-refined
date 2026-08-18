# frozen_string_literal: true

$LOAD_PATH.unshift(File.join(File.dirname(__FILE__), "..", "lib"))

require "active_record"
require "activerecord-refined"

ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
ActiveRecord::Migration.verbose = false

class Setup < ActiveRecord::Migration[8.1]
  def up
    create_table(:authors) { |t| t.string :name; t.integer :age; t.string :country; t.integer :mentor_id }
    create_table(:posts)   { |t| t.string :title; t.integer :author_id; t.integer :likes; t.boolean :published }
    create_table(:comments) { |t| t.string :body; t.integer :post_id; t.integer :score }
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

# 1. INNER JOIN + compound WHERE conditions (AND / OR / BETWEEN / IN)
query1 =
  Author.
    joins(:posts) { :posts[:author_id] == :authors[:id] }.
    where {
      (:authors[:age].in?(20..40) & (:posts[:published] == true)) |
        :authors[:country].in?(%w[JP US])
    }

puts "--- 1. INNER JOIN with compound conditions ---"
puts query1.to_sql
puts

# 2. Multi-level JOIN (authors -> posts -> comments) + negated LIKE / IN
query2 =
  Author.
    joins(:posts) { :posts[:author_id] == :authors[:id] }.
    joins(:comments) { :comments[:post_id] == :posts[:id] }.
    where {
      !:posts[:title].include?("draft") &
        !:comments[:score].in?([0, -1]) &
        (:authors[:age] >= 18)
    }

puts "--- 2. Multi-table JOIN with negated LIKE / IN ---"
puts query2.to_sql
puts

# 3. LEFT OUTER JOIN + NOT / range conditions
query3 =
  Author.
    left_outer_joins(:posts) { :posts[:author_id] == :authors[:id] }.
    where {
      !(:posts[:likes].in?(0..9) | (:posts[:published] == false))
    }

puts "--- 3. LEFT OUTER JOIN with negation ---"
puts query3.to_sql
puts

# 4. Self join.  `as` names the table within the query, and the block's
#    qualified columns go by that name, which is what makes a table joinable
#    to itself.
query4 =
  Author.
    joins(:authors, as: :mentors) { :mentors[:id] == :authors[:mentor_id] }.
    where { :mentors[:country] != :authors[:country] }.
    select { [:authors[:name].as(:author), :mentors[:name].as(:mentor)] }

puts "--- 4. Self join through an alias ---"
puts query4.to_sql
puts

# 5. The joins Active Record has no method for.  RIGHT OUTER keeps the rows of
#    the table joined rather than the one selected from; FULL OUTER keeps
#    both, which MySQL has no spelling for and this gem refuses there.
query5 =
  Author.
    right_outer_joins(:posts) { :posts[:author_id] == :authors[:id] }.
    select { [:authors[:name].as(:author), :posts[:title].as(:post)] }

puts "--- 5. RIGHT OUTER JOIN ---"
puts query5.to_sql
puts

# An association is what joins and left_outer_joins read out; these two want
# the block that says how to join.
begin
  Author.right_outer_joins(:posts)
rescue ArgumentError => e
  puts "--- and it says so without one ---"
  puts "  #{e.message}"
  puts
end

# 6. CROSS JOIN: every row against every row, so there is no condition to
#    give and no block to write it in.  `as` still names the table.
puts "--- 6. CROSS JOIN ---"
puts Author.cross_joins(:posts).to_sql
puts Author.cross_joins(:authors, as: :others).
  select { [:authors[:name].as(:a), :others[:name].as(:b)] }.to_sql
puts
