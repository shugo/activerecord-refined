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

  def test_and
    assert_match(/WHERE "users"."name" = 'matz' AND "users"."age" > 18/,
      User.where { (:name == 'matz') & (:age > 18) }.to_sql)
  end

  def test_or
    assert_match(/WHERE \(?\"users\".\"name\" = 'matz' OR \"users\".\"name\" = 'nobu'\)?/,
      User.where { (:name == 'matz') | (:name == 'nobu') }.to_sql)
  end

  def test_not
    assert_match(/WHERE NOT \(?\"users\".\"name\" = 'matz'\)?/,
      User.where { !(:name == 'matz') }.to_sql)
  end

  def test_complex_combination
    sql = User.where { ((:name == 'matz') & (:age > 18)) | !(:name == 'nobu') }.to_sql
    assert_match(/"users"."name" = 'matz'/, sql)
    assert_match(/"users"."age" > 18/, sql)
    assert_match(/NOT/, sql)
    assert_match(/OR/, sql)
  end

  def test_between
    assert_match(/WHERE "users"."age" BETWEEN 18 AND 65/,
      User.where { :age == (18..65) }.to_sql)
  end

  def test_not_like
    assert_match(/WHERE "users"."name" NOT LIKE 'tender%'/,
      User.where { :name !~ 'tender%' }.to_sql)
  end

  def test_not_between
    # Arel expands a bounded NOT BETWEEN into an OR of comparisons
    assert_match(/WHERE \("users"."age" < 18 OR "users"."age" > 65\)/,
      User.where { :age != (18..65) }.to_sql)
  end

  def test_in
    assert_match(/WHERE "users"."age" IN \(1, 2, 3\)/,
      User.where { :age == [1, 2, 3] }.to_sql)
  end

  def test_not_in
    assert_match(/WHERE "users"."age" NOT IN \(1, 2, 3\)/,
      User.where { :age != [1, 2, 3] }.to_sql)
  end

  def test_qualified_column
    assert_match(/WHERE "users"."name" = 'matz'/,
      User.where { :users[:name] == 'matz' }.to_sql)
  end

  def test_column_to_column_comparison
    sql = User.where { :users[:name] == :users[:age] }.to_sql
    assert_match(/"users"."name" = "users"."age"/, sql)
  end

  def test_joins_with_block
    sql = Author.joins(:posts) { :posts[:author_id] == :authors[:id] }.to_sql
    assert_match(/INNER JOIN "posts" ON "posts"."author_id" = "authors"."id"/, sql)
  end

  def test_left_outer_joins_with_block
    sql = Author.left_outer_joins(:posts) { :posts[:author_id] == :authors[:id] }.to_sql
    assert_match(/LEFT OUTER JOIN "posts" ON "posts"."author_id" = "authors"."id"/, sql)
  end

  def test_default_where_syntax
    assert_match(/WHERE "users"."name" = 'Ruby' AND "users"."age" = 19/,
      User.where(name: 'Ruby', age: 19).to_sql)
  end
end
