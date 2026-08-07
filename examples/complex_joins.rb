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

# 1. INNER JOIN + compound WHERE conditions (AND / OR / BETWEEN / IN)
query1 =
  Author.
    joins(:posts) { :posts[:author_id] == :authors[:id] }.
    where {
      ((:authors[:age] == (20..40)) & (:posts[:published] == true)) |
        (:authors[:country] == %w[JP US])
    }

puts "--- 1. INNER JOIN with compound conditions ---"
puts query1.to_sql
puts

# 2. Multi-level JOIN (authors -> posts -> comments) + NOT LIKE / NOT IN
query2 =
  Author.
    joins(:posts) { :posts[:author_id] == :authors[:id] }.
    joins(:comments) { :comments[:post_id] == :posts[:id] }.
    where {
      (:posts[:title] !~ '%draft%') &
        (:comments[:score] != [0, -1]) &
        (:authors[:age] >= 18)
    }

puts "--- 2. Multi-table JOIN with NOT LIKE / NOT IN ---"
puts query2.to_sql
puts

# 3. LEFT OUTER JOIN + NOT / range conditions
query3 =
  Author.
    left_outer_joins(:posts) { :posts[:author_id] == :authors[:id] }.
    where {
      !((:posts[:likes] == (0..9)) | (:posts[:published] == false))
    }

puts "--- 3. LEFT OUTER JOIN with negation ---"
puts query3.to_sql
puts
