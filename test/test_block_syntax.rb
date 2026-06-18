require_relative 'test_helper'

class TestBlockSyntax < Minitest::Test
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

  def test_is_null
    assert_match(/WHERE "users"."name" IS NULL/,
      User.where { :name.null? }.to_sql)
  end

  def test_is_null_qualified
    assert_match(/WHERE "users"."name" IS NULL/,
      User.where { :users[:name].null? }.to_sql)
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

  def test_select_aggregate
    assert_match(/SELECT SUM\("users"."age"\)/,
      User.select { :age.sum }.to_sql)
  end

  def test_select_aggregate_qualified
    assert_match(/SELECT COUNT\("users"."id"\)/,
      User.select { :users[:id].count }.to_sql)
  end

  def test_select_average
    assert_match(/SELECT AVG\("users"."age"\)/,
      User.select { :age.average }.to_sql)
  end

  def test_select_maximum
    assert_match(/SELECT MAX\("users"."age"\)/,
      User.select { :age.maximum }.to_sql)
  end

  def test_select_minimum
    assert_match(/SELECT MIN\("users"."age"\)/,
      User.select { :age.minimum }.to_sql)
  end

  def test_having_aggregate
    sql = User.group(:name).having { :age.sum > 100 }.to_sql
    assert_match(/GROUP BY "users"."name"/, sql)
    assert_match(/HAVING SUM\("users"."age"\) > 100/, sql)
  end

  def test_select_avg_function
    assert_match(/SELECT AVG\("users"."age"\)/,
      User.select { avg(:age) }.to_sql)
  end

  def test_select_count_function
    assert_match(/SELECT COUNT\("users"."id"\)/,
      User.select { count(:id) }.to_sql)
  end

  def test_select_sum_function
    assert_match(/SELECT SUM\("users"."age"\)/,
      User.select { sum(:age) }.to_sql)
  end

  def test_select_min_function
    assert_match(/SELECT MIN\("users"."age"\)/,
      User.select { min(:age) }.to_sql)
  end

  def test_select_max_function
    assert_match(/SELECT MAX\("users"."age"\)/,
      User.select { max(:age) }.to_sql)
  end

  def test_function_qualified_column
    assert_match(/SELECT AVG\("users"."age"\)/,
      User.select { avg(:users[:age]) }.to_sql)
  end

  def test_having_function
    sql = User.group(:name).having { sum(:age) > 100 }.to_sql
    assert_match(/GROUP BY "users"."name"/, sql)
    assert_match(/HAVING SUM\("users"."age"\) > 100/, sql)
  end

  def test_function_and_method_syntax_match
    assert_equal User.select { :age.average }.to_sql,
      User.select { avg(:age) }.to_sql
  end

  def test_upper_function
    assert_match(/SELECT UPPER\("users"."name"\)/,
      User.select { upper(:name) }.to_sql)
  end

  def test_lower_function
    assert_match(/SELECT LOWER\("users"."name"\)/,
      User.select { lower(:name) }.to_sql)
  end

  def test_length_function_in_where
    assert_match(/WHERE LENGTH\("users"."name"\) > 3/,
      User.where { length(:name) > 3 }.to_sql)
  end

  def test_coalesce_function_with_literal
    assert_match(/SELECT COALESCE\("users"."name", 'unknown'\)/,
      User.select { coalesce(:name, 'unknown') }.to_sql)
  end

  def test_function_comparison
    assert_match(/WHERE UPPER\("users"."name"\) = 'MATZ'/,
      User.where { upper(:name) == 'MATZ' }.to_sql)
  end

  def test_nested_function
    assert_match(/SELECT UPPER\(COALESCE\("users"."name", 'x'\)\)/,
      User.select { upper(coalesce(:name, 'x')) }.to_sql)
  end

  def test_function_qualified_column_arg
    assert_match(/SELECT UPPER\("users"."name"\)/,
      User.select { upper(:users[:name]) }.to_sql)
  end

  def test_select_multiple_fields
    assert_match(/SELECT UPPER\("users"."name"\), "users"."age"/,
      User.select { [upper(:name), :age] }.to_sql)
  end

  def test_select_multiple_columns
    assert_match(/SELECT "users"."name", "users"."age"/,
      User.select { [:name, :age] }.to_sql)
  end

  def test_select_multiple_with_aggregate
    assert_match(/SELECT "users"."name", SUM\("users"."age"\)/,
      User.select { [:name, sum(:age)] }.to_sql)
  end

  def test_select_function_with_alias
    assert_match(/SELECT UPPER\("users"."name"\) AS upper_name, "users"."age"/,
      User.select { [upper(:name).as(:upper_name), :age] }.to_sql)
  end

  def test_select_column_alias
    assert_match(/SELECT "users"."name" AS n/,
      User.select { :name.as(:n) }.to_sql)
  end

  def test_select_qualified_column_alias
    assert_match(/SELECT "users"."name" AS n/,
      User.select { :users[:name].as(:n) }.to_sql)
  end

  def test_select_aggregate_alias
    assert_match(/SELECT COUNT\("users"."id"\) AS cnt/,
      User.select { count(:id).as(:cnt) }.to_sql)
  end

  def test_order_default_asc
    assert_match(/ORDER BY "users"."age"/,
      User.order { :age }.to_sql)
  end

  def test_order_desc
    assert_match(/ORDER BY "users"."age" DESC/,
      User.order { :age.desc }.to_sql)
  end

  def test_order_asc
    assert_match(/ORDER BY "users"."age" ASC/,
      User.order { :age.asc }.to_sql)
  end

  def test_order_multiple
    assert_match(/ORDER BY "users"."age" DESC, "users"."name" ASC/,
      User.order { [:age.desc, :name.asc] }.to_sql)
  end

  def test_order_qualified_column
    assert_match(/ORDER BY "users"."name" DESC/,
      User.order { :users[:name].desc }.to_sql)
  end

  def test_default_where_syntax
    assert_match(/WHERE "users"."name" = 'Ruby' AND "users"."age" = 19/,
      User.where(name: 'Ruby', age: 19).to_sql)
  end
end
