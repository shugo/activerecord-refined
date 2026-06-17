require_relative 'test_helper'

class WhereBlockSyntaxTest < Minitest::Test
  def test_equal
    assert_match(/WHERE "users"."name" = 'matz'/, User.where { :name == 'matz' }.to_sql)
  end

  def test_not_equal
    assert_match(/WHERE "users"."name" != 'nobu'/, User.where { :name != 'nobu' }.to_sql)
  end

  def test_greater_than
    assert_match(/WHERE "users"."age" > 3/, User.where { :age > 3 }.to_sql)
  end

  def test_greater_than_or_equal
    assert_match(/WHERE "users"."age" >= 18/, User.where { :age >= 18 }.to_sql)
  end

  def test_less_than
    assert_match(/WHERE "users"."age" < 60/, User.where { :age < 60 }.to_sql)
  end

  def test_less_than_or_equal
    assert_match(/WHERE "users"."age" <= 35/, User.where { :age <= 35 }.to_sql)
  end

  def test_like
    assert_match(/WHERE "users"."name" LIKE 'tender%'/, User.where { :name =~ 'tender%' }.to_sql)
  end

  def test_outside_of_where_block
    assert_raises(ArgumentError) { :omg > 1 }
  end

  def test_default_where_syntax
    assert_match(/WHERE "users"."name" = 'Ruby' AND "users"."age" = 19/,
      User.where(name: 'Ruby', age: 19).to_sql)
  end
end
