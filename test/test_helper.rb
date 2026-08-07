$LOAD_PATH.unshift(File.join(File.dirname(__FILE__), '..', 'lib'))
$LOAD_PATH.unshift(File.dirname(__FILE__))

require 'minitest/autorun'
Bundler.require

require 'active_record'

config = {:adapter => 'sqlite3', :database => ':memory:'}
ActiveRecord::Base.establish_connection(config)

class User < ActiveRecord::Base
end

class Author < ActiveRecord::Base
  has_many :posts
end

class Post < ActiveRecord::Base
  belongs_to :author
end

class CreateAllTables < ActiveRecord::Migration[8.1]
  def up
    create_table(:users) {|t| t.string :name; t.integer :age}
    create_table(:authors) {|t| t.string :name}
    create_table(:posts) {|t| t.string :title; t.integer :author_id}
  end
end
ActiveRecord::Migration.verbose = false
CreateAllTables.new.up
