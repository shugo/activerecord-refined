$LOAD_PATH.unshift(File.join(File.dirname(__FILE__), '..', 'lib'))

require 'active_record'
require 'activerecord-refined'

ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: ':memory:')
ActiveRecord::Migration.verbose = false

class Setup < ActiveRecord::Migration[8.1]
  def up
    create_table(:authors) {|t| t.string :name }
    create_table(:posts)   {|t| t.string :title; t.integer :author_id; t.integer :likes; t.boolean :published }
  end
end
Setup.new.up

class Author < ActiveRecord::Base
  has_many :posts
end

class Post < ActiveRecord::Base
  belongs_to :author

  def self.published = where { :published == true }
end

alice  = Author.create!(name: 'alice')
bob  = Author.create!(name: 'bob')
quiet = Author.create!(name: 'quiet')

Post.create!(title: 'refinements', author_id: alice.id, likes: 100, published: true)
Post.create!(title: 'parser',      author_id: alice.id, likes: 40,  published: true)
Post.create!(title: 'draft',       author_id: bob.id, likes: 5,   published: false)

def show(title, relation)
  puts "--- #{title} ---"
  puts relation.to_sql
  puts relation.pluck(relation.model.table_name == 'authors' ? :name : :title).inspect
  puts
end

# 1. in? takes a relation as a subquery.  With an explicit select list the
#    subquery selects that column; without one it selects the primary key,
#    the same way ActiveRecord's own where(id: relation) does.
show('in? with a subquery',
  Author.where { :id.in?(Post.published.select(:author_id)) })

# 2. exists? asks whether the subquery returns a row.  Correlate it with the
#    outer table through qualified columns; the inner where block is the same
#    DSL as the outer one.
show('exists?',
  Author.where { exists?(Post.published.where { :posts[:author_id] == :authors[:id] }) })

show('!exists? finds what has nothing to show',
  Author.where { !exists?(Post.where { :posts[:author_id] == :authors[:id] }) })

# 3. A relation on the right of a comparison is a scalar subquery.  It has to
#    yield a single value, so unlike in? there is no default select list and
#    one is required.
show('a scalar subquery on the right of a comparison',
  Post.where { :likes >= Post.select { avg(:likes) } })

# The three compose like any other predicate.
show('combined with the rest of the vocabulary',
  Author.
    where { exists?(Post.where { :posts[:author_id] == :authors[:id] }) }.
    where { !:id.in?(Post.where { :published == false }.select(:author_id)) })
