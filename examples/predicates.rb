$LOAD_PATH.unshift(File.join(File.dirname(__FILE__), '..', 'lib'))

require 'active_record'
require 'activerecord-refined'

ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: ':memory:')
ActiveRecord::Migration.verbose = false

class Setup < ActiveRecord::Migration[8.1]
  def up
    create_table(:accounts) do |t|
      t.string :login
      t.string :country
      t.integer :age
      t.boolean :verified
    end
  end
end
Setup.new.up

class Account < ActiveRecord::Base
end

Account.create!(login: 'alice',     country: 'JP', age: 60, verified: true)
Account.create!(login: 'bob',       country: 'JP', age: 50, verified: false)
Account.create!(login: 'carol',     country: 'US', age: 45, verified: true)
Account.create!(login: '100%_pure', country: nil,  age: 30)
Account.create!(login: '1002000',   country: 'US', age: 25, verified: false)

def show(title, relation, rows)
  puts "--- #{title} ---"
  puts relation.to_sql
  puts rows.inspect
  puts
end

# 1. Ranges and sets.  in? is one name for "belongs to this set": a Range
#    becomes BETWEEN, an endless Range a bare comparison, a list an IN.
show('in? with a Range becomes BETWEEN',
  Account.where { :age.in?(40..55) },
  Account.where { :age.in?(40..55) }.pluck(:login))

show('endless range and IN',
  Account.where { :age.in?(50..) | :country.in?(%w[US]) },
  Account.where { :age.in?(50..) | :country.in?(%w[US]) }.pluck(:login))

# 2. NULL.  = NULL is never true in SQL, so == nil raises and the test is
#    spelled null?.  not_distinct_from? is the null-safe equality, which is
#    what to reach for when the value may or may not be nil.
show('null? and its negation',
  Account.where { :country.null? },
  Account.where { :country.null? }.pluck(:login))

wanted = nil
show('not_distinct_from? matches NULL to nil',
  Account.where { :country.not_distinct_from?(wanted) },
  Account.where { :country.not_distinct_from?(wanted) }.pluck(:login))

# Unlike !=, distinct_from? keeps the NULL row.
show('distinct_from? keeps NULLs, != drops them',
  Account.where { :country.distinct_from?('JP') },
  [
    Account.where { :country.distinct_from?('JP') }.pluck(:login),
    Account.where { :country != 'JP' }.pluck(:login),
  ])

# The truth tests answer for a NULL row where a comparison against the literal
# does not, so it is negating them that tells the two apart: not_true? has the
# unverified accounts and the one never asked, !(== true) only the former.
show('not_true? keeps the NULLs that != TRUE drops',
  Account.where { :verified.not_true? },
  [
    Account.where { :verified.not_true? }.pluck(:login),
    Account.where { !(:verified == true) }.pluck(:login),
  ])

# 3. Text.  like? takes a pattern; start_with?, end_with? and include? take
#    literals, so % and _ in them are escaped rather than matched as
#    wildcards.  Note the last row matches only the literal-minded one.
show('like? takes a pattern',
  Account.where { :login.like?('%rol') },
  Account.where { :login.like?('%rol') }.pluck(:login))

show('start_with? takes any number of literals, like String#start_with?',
  Account.where { :login.start_with?('al', 'bo') },
  Account.where { :login.start_with?('al', 'bo') }.pluck(:login))

# The % in the argument is escaped, so only the account whose login really
# contains "100%" matches; the same pattern spelled with like? treats it as a
# wildcard and catches 1002000 as well.
show('include? escapes wildcards; like? does not',
  Account.where { :login.include?('100%') },
  [
    Account.where { :login.include?('100%') }.pluck(:login),
    Account.where { :login.like?('%100%%') }.pluck(:login),
  ])

# casecmp? folds both sides rather than trusting the collation, so it means
# the same thing on every adapter.
show('casecmp? is case-insensitive equality',
  Account.where { :login.casecmp?('AlIcE') },
  Account.where { :login.casecmp?('AlIcE') }.pluck(:login))

# 4. Combining.  & | ! build the tree; Ruby's precedence puts & and | above
#    the comparison operators, hence the parentheses around each comparison.
show('compound conditions',
  Account.where { (:age >= 40) & (:country.in?(%w[JP US]) | :country.null?) },
  Account.where { (:age >= 40) & (:country.in?(%w[JP US]) | :country.null?) }.pluck(:login))
