require_relative 'test_helper'

class TestBlockSyntax < Minitest::Test
  def test_equal
    assert_sql(/WHERE "users"."name" = 'matz'/, User.where { :name == 'matz' }.to_sql)
  end

  def test_not_equal
    assert_sql(/WHERE "users"."name" != 'nobu'/, User.where { :name != 'nobu' }.to_sql)
  end

  def test_greater_than
    assert_sql(/WHERE "users"."age" > 3/, User.where { :age > 3 }.to_sql)
  end

  def test_greater_than_or_equal
    assert_sql(/WHERE "users"."age" >= 18/, User.where { :age >= 18 }.to_sql)
  end

  def test_less_than
    assert_sql(/WHERE "users"."age" < 60/, User.where { :age < 60 }.to_sql)
  end

  def test_less_than_or_equal
    assert_sql(/WHERE "users"."age" <= 35/, User.where { :age <= 35 }.to_sql)
  end

  def test_like
    assert_sql(/WHERE "users"."name" LIKE 'tender%'/, User.where { :name.like?('tender%') }.to_sql)
  end

  def test_outside_of_where_block
    assert_raises(ArgumentError) { :omg > 1 }
  end

  def test_and
    assert_sql(/WHERE "users"."name" = 'matz' AND "users"."age" > 18/,
      User.where { (:name == 'matz') & (:age > 18) }.to_sql)
  end

  def test_or
    assert_sql(/WHERE \(?\"users\".\"name\" = 'matz' OR \"users\".\"name\" = 'nobu'\)?/,
      User.where { (:name == 'matz') | (:name == 'nobu') }.to_sql)
  end

  def test_not
    assert_sql(/WHERE NOT \(?\"users\".\"name\" = 'matz'\)?/,
      User.where { !(:name == 'matz') }.to_sql)
  end

  def test_complex_combination
    sql = User.where { ((:name == 'matz') & (:age > 18)) | !(:name == 'nobu') }.to_sql
    assert_sql(/"users"."name" = 'matz'/, sql)
    assert_sql(/"users"."age" > 18/, sql)
    assert_sql(/NOT/, sql)
    assert_sql(/OR/, sql)
  end

  def test_like_qualified
    assert_sql(/WHERE "users"."name" LIKE 'tender%'/,
      User.where { :users[:name].like?('tender%') }.to_sql)
  end

  def test_not_like
    assert_sql(/WHERE NOT \("users"."name" LIKE 'tender%'\)/,
      User.where { !:name.like?('tender%') }.to_sql)
  end

  def test_start_with
    assert_sql(/WHERE "users"."name" LIKE 'tender%' ESCAPE '\\'/,
      User.where { :name.start_with?('tender') }.to_sql)
  end

  def test_end_with
    assert_sql(/WHERE "users"."name" LIKE '%love' ESCAPE '\\'/,
      User.where { :name.end_with?('love') }.to_sql)
  end

  def test_include
    assert_sql(/WHERE "users"."name" LIKE '%der%' ESCAPE '\\'/,
      User.where { :name.include?('der') }.to_sql)
  end

  def test_start_with_escapes_wildcards
    assert_sql(/WHERE "users"."name" LIKE '100\\%\\_%' ESCAPE '\\'/,
      User.where { :name.start_with?('100%_') }.to_sql)
  end

  def test_include_escapes_wildcards
    assert_sql(/WHERE "users"."name" LIKE '%100\\%%' ESCAPE '\\'/,
      User.where { :name.include?('100%') }.to_sql)
  end

  def test_regexp
    skip_without_regexp_support
    assert_sql(/WHERE "users"."name" #{regexp_operator} '\^ma'/,
      User.where { :name =~ '^ma' }.to_sql)
  end

  def test_not_regexp
    skip_without_regexp_support
    assert_sql(/WHERE "users"."name" #{not_regexp_operator} '\^ma'/,
      User.where { :name !~ '^ma' }.to_sql)
  end

  def test_regexp_qualified
    skip_without_regexp_support
    assert_sql(/WHERE "users"."name" #{regexp_operator} '\^ma'/,
      User.where { :users[:name] =~ '^ma' }.to_sql)
  end

  def test_regexp_on_function
    skip_without_regexp_support
    assert_sql(/WHERE UPPER\("users"."name"\) #{regexp_operator} '\^MA'/,
      User.where { upper(:name) =~ '^MA' }.to_sql)
  end

  def test_regexp_literal
    skip_without_regexp_support
    assert_sql(/WHERE "users"."name" #{regexp_operator} 'love\$'/,
      User.where { :name =~ /love$/ }.to_sql)
  end

  # Rejected while the block runs, so this holds on every adapter.
  def test_regexp_literal_with_options_is_rejected
    assert_raises(ArgumentError) { User.where { :name =~ /^ma/i } }
  end

  def test_between
    assert_sql(/WHERE "users"."age" BETWEEN 18 AND 65/,
      User.where { :age.between?(18, 65) }.to_sql)
  end

  def test_in_range
    assert_sql(/WHERE "users"."age" BETWEEN 18 AND 65/,
      User.where { :age.in?(18..65) }.to_sql)
  end

  def test_in_endless_range
    assert_sql(/WHERE "users"."age" >= 18/,
      User.where { :age.in?(18..) }.to_sql)
  end

  def test_in_exclusive_range
    assert_sql(/WHERE "users"."age" >= 18 AND "users"."age" < 65/,
      User.where { :age.in?(18...65) }.to_sql)
  end

  def test_not_between
    assert_sql(/WHERE NOT \("users"."age" BETWEEN 18 AND 65\)/,
      User.where { !:age.between?(18, 65) }.to_sql)
  end

  def test_is_null
    assert_sql(/WHERE "users"."name" IS NULL/,
      User.where { :name.null? }.to_sql)
  end

  def test_is_null_qualified
    assert_sql(/WHERE "users"."name" IS NULL/,
      User.where { :users[:name].null? }.to_sql)
  end

  def test_in
    assert_sql(/WHERE "users"."age" IN \(1, 2, 3\)/,
      User.where { :age.in?([1, 2, 3]) }.to_sql)
  end

  def test_in_qualified
    assert_sql(/WHERE "users"."age" IN \(1, 2, 3\)/,
      User.where { :users[:age].in?([1, 2, 3]) }.to_sql)
  end

  def test_not_in
    assert_sql(/WHERE NOT \("users"."age" IN \(1, 2, 3\)\)/,
      User.where { !:age.in?([1, 2, 3]) }.to_sql)
  end

  # == passes a Range or an Array through as a value rather than expanding it,
  # so that it compares against a PostgreSQL range or array column. The SQL
  # literal depends on the column type, so assert on the Arel node instead.
  def test_equal_range_is_an_equality
    node = ActiveRecord::Refined::AST::Comparison.new(:period, :==, 18..65).
      to_arel(User.arel_table)
    assert_instance_of(Arel::Nodes::Equality, node)
    assert_equal(18..65, node.right.value)
  end

  def test_equal_array_is_an_equality
    node = ActiveRecord::Refined::AST::Comparison.new(:tags, :==, [1, 2, 3]).
      to_arel(User.arel_table)
    assert_instance_of(Arel::Nodes::Equality, node)
    assert_equal([1, 2, 3], node.right.value)
  end

  def test_not_equal_array_is_an_inequality
    node = ActiveRecord::Refined::AST::Comparison.new(:tags, :!=, [1, 2, 3]).
      to_arel(User.arel_table)
    assert_instance_of(Arel::Nodes::NotEqual, node)
    assert_equal([1, 2, 3], node.right.value)
  end

  def test_qualified_column
    assert_sql(/WHERE "users"."name" = 'matz'/,
      User.where { :users[:name] == 'matz' }.to_sql)
  end

  def test_column_to_column_comparison
    sql = User.where { :users[:name] == :users[:age] }.to_sql
    assert_sql(/"users"."name" = "users"."age"/, sql)
  end

  def test_joins_with_block
    sql = Author.joins(:posts) { :posts[:author_id] == :authors[:id] }.to_sql
    assert_sql(/INNER JOIN "posts" ON "posts"."author_id" = "authors"."id"/, sql)
  end

  def test_left_outer_joins_with_block
    sql = Author.left_outer_joins(:posts) { :posts[:author_id] == :authors[:id] }.to_sql
    assert_sql(/LEFT OUTER JOIN "posts" ON "posts"."author_id" = "authors"."id"/, sql)
  end

  def test_select_aggregate
    assert_sql(/SELECT SUM\("users"."age"\)/,
      User.select { :age.sum }.to_sql)
  end

  def test_select_aggregate_qualified
    assert_sql(/SELECT COUNT\("users"."id"\)/,
      User.select { :users[:id].count }.to_sql)
  end

  def test_select_average
    assert_sql(/SELECT AVG\("users"."age"\)/,
      User.select { :age.average }.to_sql)
  end

  def test_select_maximum
    assert_sql(/SELECT MAX\("users"."age"\)/,
      User.select { :age.maximum }.to_sql)
  end

  def test_select_minimum
    assert_sql(/SELECT MIN\("users"."age"\)/,
      User.select { :age.minimum }.to_sql)
  end

  def test_having_aggregate
    sql = User.group(:name).having { :age.sum > 100 }.to_sql
    assert_sql(/GROUP BY "users"."name"/, sql)
    assert_sql(/HAVING SUM\("users"."age"\) > 100/, sql)
  end

  def test_select_avg_function
    assert_sql(/SELECT AVG\("users"."age"\)/,
      User.select { avg(:age) }.to_sql)
  end

  def test_select_count_function
    assert_sql(/SELECT COUNT\("users"."id"\)/,
      User.select { count(:id) }.to_sql)
  end

  def test_select_count_star
    assert_sql(/SELECT COUNT\(\*\)/,
      User.select { count(:*) }.to_sql)
  end

  def test_select_count_star_alias
    assert_sql(/SELECT COUNT\(\*\) AS cnt/,
      User.select { count(:*).as(:cnt) }.to_sql)
  end

  def test_having_count_star
    sql = Author.joins(:posts) { :posts[:author_id] == :authors[:id] }.
      group { :authors[:id] }.
      having { count(:*) > 1 }.to_sql
    assert_sql(/HAVING COUNT\(\*\) > 1/, sql)
  end

  def test_order_count_star
    assert_sql(/ORDER BY COUNT\(\*\) DESC/,
      User.group(:name).order { count(:*).desc }.to_sql)
  end

  def test_select_sum_function
    assert_sql(/SELECT SUM\("users"."age"\)/,
      User.select { sum(:age) }.to_sql)
  end

  def test_select_min_function
    assert_sql(/SELECT MIN\("users"."age"\)/,
      User.select { min(:age) }.to_sql)
  end

  def test_select_max_function
    assert_sql(/SELECT MAX\("users"."age"\)/,
      User.select { max(:age) }.to_sql)
  end

  def test_function_qualified_column
    assert_sql(/SELECT AVG\("users"."age"\)/,
      User.select { avg(:users[:age]) }.to_sql)
  end

  def test_having_function
    sql = User.group(:name).having { sum(:age) > 100 }.to_sql
    assert_sql(/GROUP BY "users"."name"/, sql)
    assert_sql(/HAVING SUM\("users"."age"\) > 100/, sql)
  end

  def test_function_and_method_syntax_match
    assert_equal User.select { :age.average }.to_sql,
      User.select { avg(:age) }.to_sql
  end

  def test_upper_function
    assert_sql(/SELECT UPPER\("users"."name"\)/,
      User.select { upper(:name) }.to_sql)
  end

  def test_lower_function
    assert_sql(/SELECT LOWER\("users"."name"\)/,
      User.select { lower(:name) }.to_sql)
  end

  def test_length_function_in_where
    assert_sql(/WHERE LENGTH\("users"."name"\) > 3/,
      User.where { length(:name) > 3 }.to_sql)
  end

  def test_coalesce_function_with_literal
    assert_sql(/SELECT COALESCE\("users"."name", 'unknown'\)/,
      User.select { coalesce(:name, 'unknown') }.to_sql)
  end

  def test_function_comparison
    assert_sql(/WHERE UPPER\("users"."name"\) = 'MATZ'/,
      User.where { upper(:name) == 'MATZ' }.to_sql)
  end

  def test_function_like
    assert_sql(/WHERE UPPER\("users"."name"\) LIKE 'MA%'/,
      User.where { upper(:name).like?('MA%') }.to_sql)
  end

  def test_function_in
    assert_sql(/WHERE UPPER\("users"."name"\) IN \('MATZ', 'NOBU'\)/,
      User.where { upper(:name).in?(%w[MATZ NOBU]) }.to_sql)
  end

  def test_aggregate_in
    assert_sql(/HAVING SUM\("users"."age"\) BETWEEN 1 AND 10/,
      User.group(:name).having { :age.sum.in?(1..10) }.to_sql)
  end

  def test_nested_function
    assert_sql(/SELECT UPPER\(COALESCE\("users"."name", 'x'\)\)/,
      User.select { upper(coalesce(:name, 'x')) }.to_sql)
  end

  def test_function_qualified_column_arg
    assert_sql(/SELECT UPPER\("users"."name"\)/,
      User.select { upper(:users[:name]) }.to_sql)
  end

  def test_select_multiple_fields
    assert_sql(/SELECT UPPER\("users"."name"\), "users"."age"/,
      User.select { [upper(:name), :age] }.to_sql)
  end

  def test_select_multiple_columns
    assert_sql(/SELECT "users"."name", "users"."age"/,
      User.select { [:name, :age] }.to_sql)
  end

  def test_select_multiple_with_aggregate
    assert_sql(/SELECT "users"."name", SUM\("users"."age"\)/,
      User.select { [:name, sum(:age)] }.to_sql)
  end

  def test_select_function_with_alias
    assert_sql(/SELECT UPPER\("users"."name"\) AS upper_name, "users"."age"/,
      User.select { [upper(:name).as(:upper_name), :age] }.to_sql)
  end

  def test_select_column_alias
    assert_sql(/SELECT "users"."name" AS n/,
      User.select { :name.as(:n) }.to_sql)
  end

  def test_select_qualified_column_alias
    assert_sql(/SELECT "users"."name" AS n/,
      User.select { :users[:name].as(:n) }.to_sql)
  end

  def test_select_aggregate_alias
    assert_sql(/SELECT COUNT\("users"."id"\) AS cnt/,
      User.select { count(:id).as(:cnt) }.to_sql)
  end

  def test_order_default_asc
    assert_sql(/ORDER BY "users"."age"/,
      User.order { :age }.to_sql)
  end

  def test_order_desc
    assert_sql(/ORDER BY "users"."age" DESC/,
      User.order { :age.desc }.to_sql)
  end

  def test_order_asc
    assert_sql(/ORDER BY "users"."age" ASC/,
      User.order { :age.asc }.to_sql)
  end

  def test_order_multiple
    assert_sql(/ORDER BY "users"."age" DESC, "users"."name" ASC/,
      User.order { [:age.desc, :name.asc] }.to_sql)
  end

  def test_order_qualified_column
    assert_sql(/ORDER BY "users"."name" DESC/,
      User.order { :users[:name].desc }.to_sql)
  end

  def test_group_single
    assert_sql(/GROUP BY "users"."name"/,
      User.group { :name }.to_sql)
  end

  def test_group_multiple
    assert_sql(/GROUP BY "users"."name", "users"."age"/,
      User.group { [:name, :age] }.to_sql)
  end

  def test_group_qualified_column
    assert_sql(/GROUP BY "users"."name"/,
      User.group { :users[:name] }.to_sql)
  end

  def test_group_with_having
    sql = User.group { :name }.having { sum(:age) > 100 }.to_sql
    assert_sql(/GROUP BY "users"."name"/, sql)
    assert_sql(/HAVING SUM\("users"."age"\) > 100/, sql)
  end

  def test_default_where_syntax
    assert_sql(/WHERE "users"."name" = 'Ruby' AND "users"."age" = 19/,
      User.where(name: 'Ruby', age: 19).to_sql)
  end
end
