require_relative 'test_helper'

class TestBlockSyntax < Minitest::Test
  def test_equal
    assert_sql(/WHERE "users"."name" = 'alice'/, User.where { :name == 'alice' }.to_sql)
  end

  def test_not_equal
    assert_sql(/WHERE "users"."name" != 'bob'/, User.where { :name != 'bob' }.to_sql)
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
    assert_sql(/WHERE "users"."name" = 'alice' AND "users"."age" > 18/,
      User.where { (:name == 'alice') & (:age > 18) }.to_sql)
  end

  def test_or
    assert_sql(/WHERE \(?\"users\".\"name\" = 'alice' OR \"users\".\"name\" = 'bob'\)?/,
      User.where { (:name == 'alice') | (:name == 'bob') }.to_sql)
  end

  def test_not
    assert_sql(/WHERE NOT \(?\"users\".\"name\" = 'alice'\)?/,
      User.where { !(:name == 'alice') }.to_sql)
  end

  def test_complex_combination
    sql = User.where { ((:name == 'alice') & (:age > 18)) | !(:name == 'bob') }.to_sql
    assert_sql(/"users"."name" = 'alice'/, sql)
    assert_sql(/"users"."age" > 18/, sql)
    assert_sql(/NOT/, sql)
    assert_sql(/OR/, sql)
  end

  def test_like_qualified
    assert_sql(/WHERE "users"."name" LIKE 'tender%'/,
      User.where { :users[:name].like?('tender%') }.to_sql)
  end

  # ILIKE is PostgreSQL's; elsewhere Arel emits LIKE, which those adapters
  # already match case-insensitively by default.
  def test_ilike
    expected = ADAPTER == 'postgresql' ? 'ILIKE' : 'LIKE'
    assert_sql(/WHERE "users"."name" #{expected} 'ma%'/,
      User.where { :name.ilike?('ma%') }.to_sql)
  end

  def test_casecmp
    assert_sql(/WHERE LOWER\("users"."name"\) = LOWER\('Alice'\)/,
      User.where { :name.casecmp?('Alice') }.to_sql)
  end

  def test_casecmp_qualified
    assert_sql(/WHERE LOWER\("users"."name"\) = LOWER\('Alice'\)/,
      User.where { :users[:name].casecmp?('Alice') }.to_sql)
  end

  def test_casecmp_nil_is_rejected
    e = assert_raises(ArgumentError) { User.where { :name.casecmp?(nil) } }
    assert_match(/null\?/, e.message)
  end

  def test_casecmp_execution
    User.delete_all
    User.create!(name: 'Alice')
    User.create!(name: 'bob')
    assert_equal(['Alice'], User.where { :name.casecmp?('aLiCe') }.pluck(:name))
  end

  def test_bang_negates_like
    assert_sql(/WHERE NOT \("users"."name" LIKE 'tender%'\)/,
      User.where { !:name.like?('tender%') }.to_sql)
  end

  def test_not_like
    assert_sql(/WHERE "users"."name" NOT LIKE 'tender%'/,
      User.where { :name.not_like?('tender%') }.to_sql)
  end

  def test_not_ilike
    expected = ADAPTER == 'postgresql' ? 'ILIKE' : 'LIKE'
    assert_sql(/WHERE "users"."name" NOT #{expected} 'tender%'/,
      User.where { :name.not_ilike?('tender%') }.to_sql)
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

  # Like their String namesakes, start_with? and end_with? take any number
  # of literals; matching any one of them is enough.
  def test_start_with_multiple
    assert_sql(
      /WHERE \("users"."name" LIKE 'al%' ESCAPE '\\' OR "users"."name" LIKE 'bo%' ESCAPE '\\'\)/,
      User.where { :name.start_with?('al', 'bo') }.to_sql)
  end

  def test_end_with_multiple
    assert_sql(
      /WHERE \("users"."name" LIKE '%z' ESCAPE '\\' OR "users"."name" LIKE '%love' ESCAPE '\\'\)/,
      User.where { :name.end_with?('z', 'love') }.to_sql)
  end

  # The OR arrives grouped, so a following & applies to the whole list.
  def test_start_with_multiple_combined
    assert_sql(
      /WHERE \("users"."name" LIKE 'al%' ESCAPE '\\' OR "users"."name" LIKE 'bo%' ESCAPE '\\'\) AND "users"."age" > 18/,
      User.where { :name.start_with?('al', 'bo') & (:age > 18) }.to_sql)
  end

  def test_start_with_no_arguments
    assert_raises(ArgumentError) { User.where { :name.start_with? } }
  end

  def test_end_with_no_arguments
    assert_raises(ArgumentError) { User.where { :name.end_with? } }
  end

  def test_start_with_escapes_wildcards
    assert_sql(/WHERE "users"."name" LIKE '100\\%\\_%' ESCAPE '\\'/,
      User.where { :name.start_with?('100%_') }.to_sql)
  end

  def test_include_escapes_wildcards
    assert_sql(/WHERE "users"."name" LIKE '%100\\%%' ESCAPE '\\'/,
      User.where { :name.include?('100%') }.to_sql)
  end

  def test_member
    assert_sql(/WHERE "users"."tags" @> '\{ruby\}'/,
      User.where { :tags.member?('ruby') }.to_sql)
  end

  def test_member_qualified
    assert_sql(/WHERE "users"."tags" @> '\{ruby\}'/,
      User.where { :users[:tags].member?('ruby') }.to_sql)
  end

  def test_member_negated
    assert_sql(/WHERE NOT \("users"."tags" @> '\{ruby\}'\)/,
      User.where { !:tags.member?('ruby') }.to_sql)
  end

  # Ruby's [1, 2].member?([1]) is false: member? tests one element, and an
  # Array argument would have to mean something the namesake does not.
  def test_member_array_is_rejected
    e = assert_raises(ArgumentError) { User.where { :tags.member?(%w[ruby rails]) } }
    assert_match(/superset\?/, e.message)
  end

  def test_superset
    assert_sql(/WHERE "users"."tags" @> '\{ruby,rails\}'/,
      User.where { :tags.superset?(%w[ruby rails]) }.to_sql)
  end

  def test_superset_takes_a_set
    assert_sql(/WHERE "users"."tags" @> '\{ruby,rails\}'/,
      User.where { :tags.superset?(Set['ruby', 'rails']) }.to_sql)
  end

  def test_superset_rejects_a_scalar
    assert_raises(ArgumentError) { User.where { :tags.superset?('ruby') } }
  end

  def test_subset
    assert_sql(/WHERE "users"."tags" <@ '\{ruby,rails,go\}'/,
      User.where { :tags.subset?(%w[ruby rails go]) }.to_sql)
  end

  def test_intersect
    assert_sql(/WHERE "users"."tags" && '\{ruby,go\}'/,
      User.where { :tags.intersect?(%w[ruby go]) }.to_sql)
  end

  def test_intersect_negated
    assert_sql(/WHERE NOT \("users"."tags" && '\{ruby,go\}'\)/,
      User.where { !:tags.intersect?(%w[ruby go]) }.to_sql)
  end

  def test_array_comparisons_execution
    skip_without_array_columns
    User.delete_all
    User.create!(name: 'both', tags: %w[ruby rails])
    User.create!(name: 'one', tags: %w[ruby go])
    User.create!(name: 'neither', tags: %w[python])
    assert_equal(['both'], User.where { :tags.superset?(%w[ruby rails]) }.pluck(:name))
    assert_equal(['neither'], User.where { :tags.subset?(%w[python js]) }.pluck(:name))
    assert_equal(%w[both one],
      User.where { :tags.intersect?(%w[ruby js]) }.pluck(:name).sort)
  end

  # MySQL additionally escapes the double quotes inside its string literal,
  # so the exact spelling is only asserted where the operator is real.
  def test_member_quotes_special_elements
    skip_without_array_columns
    assert_sql(/WHERE "users"."tags" @> '\{"with,comma"\}'/,
      User.where { :tags.member?('with,comma') }.to_sql)
  end

  # include? is a substring match even on an array column; only member?
  # means containment.
  def test_include_is_like_even_on_array_columns
    skip_without_array_columns
    assert_sql(/WHERE "users"."tags" LIKE '%ruby%' ESCAPE '\\'/,
      User.where { :tags.include?('ruby') }.to_sql)
  end

  # Elements survive the trip through the array literal: % is an ordinary
  # character there, a comma stays inside its element, and quotes and
  # backslashes are escaped.
  def test_member_matches_elements_literally
    skip_without_array_columns
    User.delete_all
    User.create!(name: 'literal', tags: ['100%', 'with,comma', 'q"uote', 'back\\slash'])
    User.create!(name: 'lookalike', tags: ['100200', 'with', 'comma'])
    assert_equal(['literal'], User.where { :tags.member?('100%') }.pluck(:name))
    assert_equal(['literal'], User.where { :tags.member?('with,comma') }.pluck(:name))
    assert_equal(['literal'], User.where { :tags.member?('q"uote') }.pluck(:name))
    assert_equal(['literal'], User.where { :tags.member?('back\\slash') }.pluck(:name))
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

  def test_bang_negates_between
    assert_sql(/WHERE NOT \("users"."age" BETWEEN 18 AND 65\)/,
      User.where { !:age.between?(18, 65) }.to_sql)
  end

  # Arel spells the negation as the two comparisons rather than NOT BETWEEN,
  # which is the same set of rows, NULLs included.
  def test_not_between
    assert_sql(/WHERE \("users"."age" < 18 OR "users"."age" > 65\)/,
      User.where { :age.not_between?(18, 65) }.to_sql)
  end

  def test_not_in_range
    assert_sql(/WHERE \("users"."age" < 18 OR "users"."age" > 65\)/,
      User.where { :age.not_in?(18..65) }.to_sql)
  end

  def test_is_null
    assert_sql(/WHERE "users"."name" IS NULL/,
      User.where { :name.null? }.to_sql)
  end

  def test_is_null_qualified
    assert_sql(/WHERE "users"."name" IS NULL/,
      User.where { :users[:name].null? }.to_sql)
  end

  def test_is_not_null
    assert_sql(/WHERE "users"."name" IS NOT NULL/,
      User.where { :name.not_null? }.to_sql)
  end

  def test_is_not_null_qualified
    assert_sql(/WHERE "users"."name" IS NOT NULL/,
      User.where { :users[:name].not_null? }.to_sql)
  end

  # CASE has two shapes, and so does the block: an operand to compare each
  # `when` against, or a condition on every `when`.
  def test_case_with_an_operand
    assert_sql(/SELECT CASE "users"."age" WHEN 10 THEN 'ten' ELSE 'other' END AS "v"/,
      User.select { self.case(:age).when(10).then('ten').else('other').as(:v) }.to_sql)
  end

  def test_when_on_a_column_is_the_same_case
    assert_equal(
      User.select { self.case(:age).when(10).then('ten').else('other').as(:v) }.to_sql,
      User.select { :age.when(10).then('ten').else('other').as(:v) }.to_sql)
  end

  def test_searched_case
    assert_sql(/SELECT CASE WHEN "users"."age" >= 60 THEN 'senior' ELSE 'other' END AS "v"/,
      User.select { case_when { :age >= 60 }.then('senior').else('other').as(:v) }.to_sql)
  end

  def test_case_when_is_the_same_as_case_with_no_operand
    assert_equal(
      User.select { self.case.when { :age >= 60 }.then(1).else(0).as(:v) }.to_sql,
      User.select { case_when { :age >= 60 }.then(1).else(0).as(:v) }.to_sql)
  end

  # A value and a block say the same thing; the block is there to read like
  # the blocks around it.
  def test_a_condition_reads_the_same_either_way
    assert_equal(
      User.select { case_when(:age >= 60).then(1).else(0).as(:v) }.to_sql,
      User.select { case_when { :age >= 60 }.then(1).else(0).as(:v) }.to_sql)
  end

  def test_case_with_several_whens
    assert_sql(
      /CASE WHEN "users"."age" < 18 THEN 'minor' WHEN "users"."age" >= 60 THEN 'senior' ELSE 'adult' END/,
      User.select {
        case_when { :age < 18 }.then('minor').
          when { :age >= 60 }.then('senior').
          else('adult').as(:v)
      }.to_sql)
  end

  # Leaving the ELSE off is SQL's own default rather than an omission.
  def test_case_without_an_else
    sql = User.select { case_when { :age >= 60 }.then('senior').as(:v) }.to_sql
    assert_sql(/CASE WHEN "users"."age" >= 60 THEN 'senior' END/, sql)
    refute_match(/ELSE/, sql)
  end

  def test_case_takes_expressions_and_columns
    assert_sql(/THEN \("users"."age" - 60\)/,
      User.select { case_when { :age >= 60 }.then { :age - 60 }.else(0).as(:v) }.to_sql)
    assert_sql(/THEN "users"."name"/,
      User.select { case_when { :age >= 60 }.then(:name).else('x').as(:v) }.to_sql)
  end

  def test_case_is_an_expression_like_any_other
    assert_sql(/SUM\(CASE WHEN/,
      User.select { sum(case_when { :age >= 60 }.then(1).else(0)).as(:v) }.to_sql)
    assert_sql(/WHERE CASE "users"."age" WHEN 10 THEN 1 ELSE 2 END = 1/,
      User.where { self.case(:age).when(10).then(1).else(2) == 1 }.to_sql)
  end

  def test_case_execution
    User.delete_all
    User.create!(name: 'senior', age: 70)
    User.create!(name: 'adult', age: 30)
    User.create!(name: 'minor', age: 10)
    assert_equal(%w[adult minor senior],
      User.select {
        case_when { :age < 18 }.then('minor').
          when { :age >= 60 }.then('senior').
          else('adult').as(:v)
      }.map(&:v).sort)
  end

  # One case finished two ways: the methods return new nodes rather than
  # adding to the one they were called on.
  def test_a_case_is_not_added_to_in_place
    sql = User.select {
      started = case_when { :age >= 60 }.then(1)
      [started.else(0).as(:a), started.else(9).as(:b)]
    }.to_sql
    assert_sql(/THEN 1 ELSE 0 END AS "a"/, sql)
    assert_sql(/THEN 1 ELSE 9 END AS "b"/, sql)
  end

  def test_when_needs_a_value_or_a_block
    assert_raises(ArgumentError) { User.select { case_when.then(1) } }
    e = assert_raises(ArgumentError) { User.select { case_when(1) { 2 }.then(1) } }
    assert_match(/not both/, e.message)
  end

  def test_when_needs_a_matching_then
    e = assert_raises(ArgumentError) { User.select { :age.when(10) }.to_sql }
    assert_match(/matching then/, e.message)
  end

  # Kernel#then would otherwise answer this one, with no block and no noise.
  def test_then_without_a_when_says_so
    e = assert_raises(ArgumentError) { User.select { self.case(:age).then(1) } }
    assert_match(/follows a when/, e.message)
  end

  # A window is built by chaining, the way Arel's own is.
  def test_over_with_no_window
    assert_sql(/SELECT AVG\("users"."age"\) OVER \(\) AS "v"/,
      User.select { avg(:age).over.as(:v) }.to_sql)
  end

  def test_over_partition_and_order
    assert_sql(
      /AVG\("users"."age"\) OVER \(PARTITION BY "users"."name" ORDER BY "users"."age" DESC\)/,
      User.select { avg(:age).over.partition(:name).order(:age.desc).as(:v) }.to_sql)
  end

  def test_over_takes_several_expressions
    assert_sql(/PARTITION BY "users"."name", "users"."age"/,
      User.select { count(:*).over.partition(:name, :age).as(:v) }.to_sql)
  end

  # The window-only functions, which the adapters that have them at all spell
  # the same way.
  def test_window_functions
    assert_sql(/ROW_NUMBER\(\) OVER \(ORDER BY "users"."age"\)/,
      User.select { row_number.over.order(:age).as(:v) }.to_sql)
    assert_sql(/RANK\(\) OVER/, User.select { rank.over.order(:age).as(:v) }.to_sql)
    assert_sql(/NTILE\(2\) OVER/, User.select { ntile(2).over.order(:age).as(:v) }.to_sql)
    assert_sql(/LAG\("users"."age", 1\) OVER/,
      User.select { lag(:age).over.order(:age).as(:v) }.to_sql)
    assert_sql(/LAG\("users"."age", 2, 0\) OVER/,
      User.select { lag(:age, 2, 0).over.order(:age).as(:v) }.to_sql)
  end

  # A frame is a range of rows counted from the current one: negative before
  # it, positive after, 0 the row itself, an open end for unbounded.
  def test_window_frames
    assert_sql(/ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW/,
      User.select { sum(:age).over.order(:age).rows(..0).as(:v) }.to_sql)
    assert_sql(/ROWS BETWEEN 1 PRECEDING AND 1 FOLLOWING/,
      User.select { sum(:age).over.order(:age).rows(-1..1).as(:v) }.to_sql)
    assert_sql(/ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING/,
      User.select { sum(:age).over.order(:age).rows(0..).as(:v) }.to_sql)
    assert_sql(/RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW/,
      User.select { sum(:age).over.order(:age).range(..0).as(:v) }.to_sql)
  end

  def test_over_is_an_expression_like_any_other
    assert_sql(/\(RANK\(\) OVER \(ORDER BY "users"."age"\) \+ 1\) AS "v"/,
      User.select { (rank.over.order(:age) + 1).as(:v) }.to_sql)
  end

  def test_window_execution
    User.delete_all
    User.create!(name: 'a', age: 20)
    User.create!(name: 'b', age: 30)
    User.create!(name: 'c', age: 40)
    assert_equal([1, 2, 3],
      User.select { row_number.over.order(:age).as(:v) }.map {|u| u.v.to_i })
    assert_equal([20, 50, 90],
      User.select { sum(:age).over.order(:age).rows(..0).as(:v) }.map {|u| u.v.to_i })
  end

  # One window finished two ways: the methods return new nodes.
  def test_a_window_is_not_added_to_in_place
    sql = User.select {
      started = sum(:age).over.order(:age)
      [started.partition(:name).as(:a), started.as(:b)]
    }.to_sql
    assert_sql(/PARTITION BY "users"."name" ORDER BY "users"."age"\) AS "a"/, sql)
    assert_sql(/SUM\("users"."age"\) OVER \(ORDER BY "users"."age"\) AS "b"/, sql)
  end

  def test_a_window_function_needs_over
    e = assert_raises(ArgumentError) { User.select { row_number.as(:v) }.to_sql }
    assert_match(/needs over/, e.message)
  end

  def test_a_window_has_one_frame
    assert_raises(ArgumentError) { User.select { sum(:age).over.rows(..0).range(..0) } }
  end

  def test_a_frame_is_a_range_of_rows
    assert_raises(ArgumentError) { User.select { sum(:age).over.rows(3) } }
    assert_raises(ArgumentError) { User.select { sum(:age).over.rows('a'..'b') } }
    e = assert_raises(ArgumentError) { User.select { sum(:age).over.rows(-2...0) } }
    assert_match(/ends on a row/, e.message)
  end

  def test_partition_needs_an_expression
    assert_raises(ArgumentError) { User.select { sum(:age).over.partition } }
    assert_raises(ArgumentError) { User.select { sum(:age).over.order } }
  end

  def test_case_needs_a_when
    e = assert_raises(ArgumentError) { User.select { self.case(:age).else(1) }.to_sql }
    assert_match(/needs a when/, e.message)
  end

  # The claim these methods rest on: the direct spelling is the same rows as
  # negating the positive one, which is where a NULL would show a difference
  # if there were one.
  def test_the_negations_match_what_bang_selects
    User.delete_all
    User.create!(name: 'alice', age: 60)
    User.create!(name: 'bob', age: 20)
    User.create!(name: nil, age: 40)
    [
      [-> { :name.not_null? },          -> { !:name.null? }],
      [-> { :age.not_in?([20, 30]) },   -> { !:age.in?([20, 30]) }],
      [-> { :age.not_between?(20, 30) }, -> { !:age.between?(20, 30) }],
      [-> { :name.not_like?('a%') },    -> { !:name.like?('a%') }],
    ].each do |direct, negated|
      assert_equal(User.where(&negated).pluck(:id).sort,
                   User.where(&direct).pluck(:id).sort,
                   "#{direct.source_location} did not match the ! form")
    end
  end

  def test_equal_nil_is_rejected
    e = assert_raises(ArgumentError) { User.where { :name == nil } }
    assert_match(/null\?/, e.message)
  end

  def test_not_equal_nil_is_rejected
    e = assert_raises(ArgumentError) { User.where { :name != nil } }
    assert_match(/null\?/, e.message)
  end

  def test_in
    assert_sql(/WHERE "users"."age" IN \(1, 2, 3\)/,
      User.where { :age.in?([1, 2, 3]) }.to_sql)
  end

  def test_in_qualified
    assert_sql(/WHERE "users"."age" IN \(1, 2, 3\)/,
      User.where { :users[:age].in?([1, 2, 3]) }.to_sql)
  end

  def test_bang_negates_in
    assert_sql(/WHERE NOT \("users"."age" IN \(1, 2, 3\)\)/,
      User.where { !:age.in?([1, 2, 3]) }.to_sql)
  end

  def test_not_in
    assert_sql(/WHERE "users"."age" NOT IN \(1, 2, 3\)/,
      User.where { :age.not_in?([1, 2, 3]) }.to_sql)
  end

  def test_not_in_qualified
    assert_sql(/WHERE "users"."age" NOT IN \(1, 2, 3\)/,
      User.where { :users[:age].not_in?([1, 2, 3]) }.to_sql)
  end

  # Spelled IS [NOT] DISTINCT FROM on PostgreSQL, IS / IS NOT on SQLite and
  # <=> on MySQL, so only the resulting rows are portable.
  def test_not_distinct_from_execution
    User.delete_all
    User.create!(name: 'named')
    User.create!(name: nil)
    assert_equal([nil], User.where { :name.not_distinct_from?(nil) }.pluck(:name))
    assert_equal(['named'], User.where { :name.distinct_from?(nil) }.pluck(:name))
  end

  def test_not_distinct_from_a_value_execution
    User.delete_all
    User.create!(name: 'alice')
    User.create!(name: nil)
    assert_equal(['alice'], User.where { :name.not_distinct_from?('alice') }.pluck(:name))
    # Unlike !=, this keeps the NULL row.
    assert_equal([nil], User.where { :name.distinct_from?('alice') }.pluck(:name))
  end

  def test_distinct_from_postgresql_syntax
    skip "#{ADAPTER} spells it differently" unless ADAPTER == 'postgresql'
    assert_sql(/WHERE "users"."name" IS NOT DISTINCT FROM 'x'/,
      User.where { :name.not_distinct_from?('x') }.to_sql)
    assert_sql(/WHERE "users"."name" IS DISTINCT FROM 'x'/,
      User.where { :name.distinct_from?('x') }.to_sql)
  end

  def test_comparison_with_scalar_subquery
    assert_sql(/WHERE "users"."age" >= \(SELECT AVG\("users"."age"\) FROM "users"\)/,
      User.where { :age >= User.select { avg(:age) } }.to_sql)
  end

  def test_equality_with_scalar_subquery
    assert_sql(/WHERE "users"."age" = \(SELECT MAX\("users"."age"\) FROM "users"\)/,
      User.where { :age == User.select { max(:age) } }.to_sql)
  end

  # A scalar comparison has no sensible default select list, unlike in?.
  def test_scalar_subquery_without_select_is_rejected
    e = assert_raises(ArgumentError) { User.where { :age >= User.all } }
    assert_match(/select/, e.message)
  end

  def test_scalar_subquery_execution
    User.delete_all
    User.create!(name: 'young', age: 20)
    User.create!(name: 'old', age: 60)
    assert_equal(['old'], User.where { :age >= User.select { avg(:age) } }.pluck(:name))
  end

  def test_in_subquery
    assert_sql(
      /WHERE "authors"."id" IN \(SELECT "posts"."author_id" FROM "posts" WHERE "posts"."title" = 'pub'\)/,
      Author.where { :id.in?(Post.where(title: 'pub').select(:author_id)) }.to_sql)
  end

  # A relation without an explicit select list selects its primary key, the
  # same way ActiveRecord's own where(id: relation) does.
  def test_in_subquery_selects_primary_key_by_default
    assert_sql(/WHERE "authors"."id" IN \(SELECT "posts"."id" FROM "posts"\)/,
      Author.where { :id.in?(Post.all) }.to_sql)
  end

  def test_not_in_subquery
    assert_sql(/WHERE NOT \("authors"."id" IN \(SELECT "posts"."author_id" FROM "posts"\)\)/,
      Author.where { !:id.in?(Post.select(:author_id)) }.to_sql)
  end

  # The subquery correlates with the outer table through qualified columns,
  # and its own where block goes through the DSL too.
  def test_exists
    assert_sql(
      /WHERE EXISTS \(SELECT "posts"\.\* FROM "posts" WHERE "posts"."author_id" = "authors"."id"\)/,
      Author.where { exists?(Post.where { :posts[:author_id] == :authors[:id] }) }.to_sql)
  end

  def test_not_exists
    assert_sql(/WHERE NOT \(EXISTS \(SELECT "posts"\.\* FROM "posts"\)\)/,
      Author.where { !exists?(Post.all) }.to_sql)
  end

  def test_exists_combined
    assert_sql(
      /WHERE "authors"."name" = 'alice' AND EXISTS \(SELECT "posts"\.\* FROM "posts" WHERE "posts"."title" = 'pub'\)/,
      Author.where { (:name == 'alice') & exists?(Post.where(title: 'pub')) }.to_sql)
  end

  def test_exists_execution
    Author.delete_all
    Post.delete_all
    with_post = Author.create!(name: 'with_post')
    Author.create!(name: 'without')
    Post.create!(title: 'pub', author_id: with_post.id)
    correlated = -> { Post.where { :posts[:author_id] == :authors[:id] } }
    assert_equal(['with_post'],
      Author.where { exists?(correlated.call) }.pluck(:name))
    assert_equal(['without'],
      Author.where { !exists?(correlated.call) }.pluck(:name))
  end

  def test_in_subquery_execution
    Author.delete_all
    Post.delete_all
    published = Author.create!(name: 'published')
    drafting = Author.create!(name: 'drafting')
    Post.create!(title: 'pub', author_id: published.id)
    Post.create!(title: 'draft', author_id: drafting.id)
    subquery = -> { Post.where(title: 'pub').select(:author_id) }
    assert_equal(['published'],
      Author.where { :id.in?(subquery.call) }.pluck(:name))
    assert_equal(['drafting'],
      Author.where { !:id.in?(subquery.call) }.pluck(:name))
  end

  # == passes a Range or an Array through as a value rather than expanding it,
  # so that it compares against a PostgreSQL range or array column. The SQL
  # literal depends on the column type, so assert on the Arel node instead.
  def test_equal_range_is_an_equality
    node = ActiveRecord::Refined::AST::Comparison.new(:period, :==, 18..65).
      to_arel(User.arel_table, User)
    assert_instance_of(Arel::Nodes::Equality, node)
    assert_equal(18..65, node.right.value)
  end

  def test_equal_array_is_an_equality
    node = ActiveRecord::Refined::AST::Comparison.new(:tags, :==, [1, 2, 3]).
      to_arel(User.arel_table, User)
    assert_instance_of(Arel::Nodes::Equality, node)
    assert_equal([1, 2, 3], node.right.value)
  end

  def test_not_equal_array_is_an_inequality
    node = ActiveRecord::Refined::AST::Comparison.new(:tags, :!=, [1, 2, 3]).
      to_arel(User.arel_table, User)
    assert_instance_of(Arel::Nodes::NotEqual, node)
    assert_equal([1, 2, 3], node.right.value)
  end

  def test_qualified_column
    assert_sql(/WHERE "users"."name" = 'alice'/,
      User.where { :users[:name] == 'alice' }.to_sql)
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

  # The alias is what the block's qualified columns name, which is what makes
  # a self join expressible at all.  Adapters differ on writing the AS
  # keyword, so the assertions allow either.
  def test_joins_with_alias
    assert_sql(
      /INNER JOIN "authors" (?:AS )?"mentors" ON "mentors"."id" = "authors"."id"/,
      Author.joins(:authors, as: :mentors) { :mentors[:id] == :authors[:id] }.to_sql)
  end

  def test_left_outer_joins_with_alias
    assert_sql(
      /LEFT OUTER JOIN "authors" (?:AS )?"mentors" ON "mentors"."id" = "authors"."id"/,
      Author.left_outer_joins(:authors, as: :mentors) { :mentors[:id] == :authors[:id] }.to_sql)
  end

  def test_joins_alias_needs_a_block
    assert_raises(ArgumentError) { Author.joins(:posts, as: :p) }
    assert_raises(ArgumentError) { Author.left_outer_joins(:posts, as: :p) }
  end

  def test_joins_without_alias_still_delegates
    assert_sql(/INNER JOIN "posts" ON "posts"."author_id" = "authors"."id"/,
      Author.joins(:posts).to_sql)
  end

  def test_self_join_execution
    Author.delete_all
    Author.create!(name: 'shared')
    Author.create!(name: 'other')
    assert_equal(%w[other shared],
      Author.joins(:authors, as: :mentors) { :mentors[:name] == :authors[:name] }.
        pluck(:name).sort)
  end

  # ActiveRecord's from only takes a table name as a string.
  def test_from_symbol
    assert_sql(/FROM "tree"/, Node.from(:tree).to_sql)
  end

  def test_from_symbol_with_alias
    assert_sql(/FROM "tree" (?:AS )?"nodes"/, Node.from(:tree, as: :nodes).to_sql)
  end

  def test_from_string_still_delegates
    assert_sql(/FROM subq/, Node.from('subq').to_sql)
  end

  def test_from_alias_needs_a_symbol
    assert_raises(ArgumentError) { Node.from('tree', as: :nodes) }
  end

  def test_from_cte_takes_the_alias_from_the_model
    assert_sql(/FROM "tree" (?:AS )?"nodes"/, Node.from_cte(:tree).to_sql)
    assert_equal(Node.from(:tree, as: :nodes).to_sql, Node.from_cte(:tree).to_sql)
  end

  def test_from_cte_needs_a_symbol
    assert_raises(ArgumentError) { Node.from_cte('tree') }
  end

  # The alias is what lets a where find its column, which is the whole reason
  # from_cte exists; without it the SQL names a table the query does not have.
  def test_from_cte_leaves_where_able_to_qualify
    Node.delete_all
    root = Node.create!(name: 'root')
    Node.create!(name: 'child', parent_id: root.id)
    other = Node.create!(name: 'other root')
    Node.create!(name: 'other child', parent_id: other.id)
    forest = Node.with_recursive(
      tree: [
        Node.where { :parent_id.null? }.
          select { [:id, :name, :parent_id, :id.as(:root_id)] },
        Node.joins(:tree) { :nodes[:parent_id] == :tree[:id] }.
          select { [:nodes[:id], :nodes[:name], :nodes[:parent_id],
                    :tree[:root_id]] },
      ]
    ).from_cte(:tree)
    assert_equal(%w[child root],
      forest.where { :root_id == root.id }.pluck(:name).sort)
  end

  # A CTE is joined by name like any other table, so the recursive member's
  # ON clause is a block rather than the string join Rails' own docs use.
  def test_recursive_cte
    Node.delete_all
    root = Node.create!(name: 'root')
    child = Node.create!(name: 'child', parent_id: root.id)
    Node.create!(name: 'grandchild', parent_id: child.id)
    Node.create!(name: 'unrelated', parent_id: nil)
    descendants = Node.with_recursive(
      tree: [
        Node.where { :id == root.id },
        Node.joins(:tree) { :nodes[:parent_id] == :tree[:id] },
      ]
    ).from(:tree, as: :nodes)
    assert_equal(%w[child grandchild root], descendants.pluck(:name).sort)
  end

  def test_cte_joined_by_name
    Node.delete_all
    root = Node.create!(name: 'root')
    Node.create!(name: 'child', parent_id: root.id)
    Node.create!(name: 'orphan', parent_id: nil)
    q = Node.with(roots: Node.where { :parent_id.null? }).
      joins(:roots) { :roots[:id] == :nodes[:parent_id] }
    assert_equal(['child'], q.pluck(:name))
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
    assert_sql(/SELECT COUNT\(\*\) AS "cnt"/,
      User.select { count(:*).as(:cnt) }.to_sql)
  end

  def test_count_distinct
    assert_sql(/SELECT COUNT\(DISTINCT "users"."name"\)/,
      User.select { count(:name, distinct: true) }.to_sql)
  end

  def test_count_distinct_as_method
    assert_sql(/SELECT COUNT\(DISTINCT "users"."name"\) AS "n"/,
      User.select { :name.count(distinct: true).as(:n) }.to_sql)
  end

  def test_count_distinct_in_having
    assert_sql(/HAVING COUNT\(DISTINCT "users"."name"\) > 1/,
      User.group(:age).having { count(:name, distinct: true) > 1 }.to_sql)
  end

  # DISTINCT is Arel's only aggregate modifier, and COUNT(DISTINCT *) is not
  # valid SQL.
  def test_distinct_is_rejected_for_other_aggregates
    assert_raises(ArgumentError) do
      ActiveRecord::Refined::AST::Aggregate.new(:age, :sum, distinct: true)
    end
  end

  def test_count_star_distinct_is_rejected
    assert_raises(ArgumentError) { User.select { count(:*, distinct: true) } }
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

  # fn emits the name as written, so a case-sensitive one can be spelled
  # exactly.
  def test_fn
    assert_sql(/SELECT date_trunc\('day', "users"."name"\)/,
      User.select { fn(:date_trunc, 'day', :name) }.to_sql)
  end

  def test_fn_is_comparable
    assert_sql(/WHERE char_length\("users"."name"\) > 3/,
      User.where { fn(:char_length, :name) > 3 }.to_sql)
  end

  def test_fn_alias
    assert_sql(/SELECT date_trunc\('day', "users"."name"\) AS "d"/,
      User.select { fn(:date_trunc, 'day', :name).as(:d) }.to_sql)
  end

  # Aliases and function names are written into the SQL where a value would
  # have been quoted, so a name that is not plain is refused rather than
  # given the chance to close the identifier and carry on.
  INJECTION = %q{a" AS x, (SELECT 1) AS "y}

  # An alias that is not a plain name is quoted by the adapter rather than
  # refused, so an injected one becomes an alias with a strange name and
  # nothing else.  Each spells the quoting its own way, so what is asserted is
  # that the payload arrived as the name of the column it labelled.
  def test_an_injected_alias_is_quoted_rather_than_refused
    User.delete_all
    User.create!(name: 'alice')
    payload = 'a" FROM users; --'
    row = User.select { :name.as(payload.to_sym) }.first
    assert_equal('alice', row[payload])
    assert_equal(1, User.count)
  end

  def test_an_alias_that_needs_quoting_gets_it
    assert_sql(/AS "total sales"/, User.select { :name.as(:'total sales') }.to_sql)
    assert_sql(/AS "select"/, User.select { :name.as(:select, quote: true) }.to_sql)
    assert_sql(/AS "up per"/, User.select { upper(:name).as(:'up per') }.to_sql)
    assert_sql(/AS "d epth"/, User.select { 0.as(:'d epth') }.to_sql)
  end

  # Quoted, the name asked for is the name that comes back.  Unquoted,
  # PostgreSQL would fold the capital away and the other two would keep it.
  def test_an_alias_keeps_the_name_as_written
    assert_sql(/AS "postCount"/, User.select { :name.as(:postCount) }.to_sql)
    User.delete_all
    User.create!(name: 'alice')
    assert_equal('alice', User.select { :name.as(:postCount) }.first['postCount'])
  end

  def test_quote_false_asks_for_the_name_as_it_is
    assert_sql(/AS post_count/, User.select { :name.as(:post_count, quote: false) }.to_sql)
    refute_match(/"post_count"/,
      normalize_sql(User.select { :name.as(:post_count, quote: false) }.to_sql))
  end

  # Nothing quotes it, so a name that would be SQL has to be refused.
  def test_quote_false_refuses_a_name_that_is_not_plain
    e = assert_raises(ArgumentError) { User.select { :name.as(:'total sales', quote: false) } }
    assert_match(/plain column alias/, e.message)
    assert_raises(ArgumentError) { User.select { :name.as(INJECTION.to_sym, quote: false) } }
  end

  def test_fn_rejects_an_injected_name
    assert_raises(ArgumentError) { User.select { fn(INJECTION.to_sym, :name) } }
  end

  def test_plain_names_are_still_accepted
    assert_sql(/AS "post_count"/, User.select { :name.as(:post_count) }.to_sql)
    assert_sql(/AS "名前"/, User.select { :name.as(:名前) }.to_sql)
    assert_sql(/SELECT myFunc\(/, User.select { fn(:myFunc, :name) }.to_sql)
    assert_sql(/SELECT pg_catalog.upper\(/,
      User.select { fn(:'pg_catalog.upper', :name) }.to_sql)
  end

  # Values go through the adapter's quoting, which each spells its own way,
  # so what is asserted is that the payload stays a value: it matches no row
  # rather than opening the condition up.
  def test_values_are_quoted
    User.delete_all
    User.create!(name: 'alice')
    User.create!(name: 'bob')
    payload = "x' OR 1=1 --"
    assert_empty(User.where { :name == payload }.pluck(:name))
    assert_empty(User.where { :name.like?(payload) }.pluck(:name))
    assert_empty(User.where { :name.in?([payload]) }.pluck(:name))
    assert_empty(User.where { :name.include?(payload) }.pluck(:name))
  end

  # Likewise for column names: the payload becomes one identifier, so the
  # database rejects it as an unknown column instead of running it.
  def test_column_names_are_quoted
    assert_raises(ActiveRecord::StatementInvalid) do
      User.where { :users[INJECTION.to_sym] == 1 }.to_a
    end
  end

  def test_scalar_functions_shared_by_every_adapter
    assert_sql(/SELECT CONCAT\(UPPER\("users"."name"\), 'x'\)/,
      User.select { concat(upper(:name), 'x') }.to_sql)
    assert_sql(/WHERE MOD\("users"."age", 7\) = 0/,
      User.where { mod(:age, 7) == 0 }.to_sql)
  end

  # SQLite has no CHAR_LENGTH, GREATEST or LEAST, but LENGTH, MAX and MIN
  # mean the same thing there.
  def test_scalar_functions_spelled_differently_on_sqlite
    expected = ADAPTER == 'sqlite3' ? %w[LENGTH MAX MIN] : %w[CHAR_LENGTH GREATEST LEAST]
    assert_sql(/SELECT #{expected[0]}\("users"."name"\)/,
      User.select { char_length(:name) }.to_sql)
    assert_sql(/SELECT #{expected[1]}\("users"."age", 18\)/,
      User.select { greatest(:age, 18) }.to_sql)
    assert_sql(/SELECT #{expected[2]}\("users"."age", 99\)/,
      User.select { least(:age, 99) }.to_sql)
  end

  def test_scalar_functions_run
    User.delete_all
    User.create!(name: 'alice', age: 60)
    assert_equal(['ALICE-x'], User.select { concat(upper(:name), '-x').as(:v) }.map(&:v))
    assert_equal([5], User.select { char_length(:name).as(:v) }.map(&:v))
    assert_equal([60], User.select { greatest(:age, 18).as(:v) }.map(&:v))
  end

  # rand takes the name back from Kernel#rand, which would otherwise answer
  # inside the block and never reach the database.
  def test_rand
    expected = ADAPTER == 'mysql2' ? 'RAND' : 'RANDOM'
    assert_sql(/ORDER BY #{expected}\(\)/, User.order { rand }.to_sql)
  end

  # Where an adapter has no equivalent, the block raises instead of leaving
  # the database to reject the SQL.
  def test_unsupported_function_raises
    if ADAPTER == 'postgresql'
      assert_sql(/SELECT DATE_TRUNC\('day', "users"."name"\)/,
        User.select { date_trunc('day', :name) }.to_sql)
    else
      e = assert_raises(NotImplementedError) { User.select { date_trunc('day', :name) } }
      assert_match(/date_trunc/, e.message)
    end
  end

  # MySQL's FORMAT is a different function that happens to share the name,
  # and reads a printf template as the number zero rather than complaining,
  # so the name carries the printf one and MySQL raises.
  def test_format_is_printf_and_unsupported_on_mysql
    if ADAPTER == 'mysql2'
      assert_raises(NotImplementedError) { User.select { format('%s!', :name) } }
    else
      User.delete_all
      User.create!(name: 'alice')
      assert_equal(['alice!'], User.select { format('%s!', :name).as(:v) }.map(&:v))
    end
  end

  # MySQL's own is still reachable, spelled as the different thing it is.
  def test_mysql_format_through_fn
    assert_sql(/SELECT format\(1234.5678, 2\)/,
      User.select { fn(:format, 1234.5678, 2) }.to_sql)
  end

  def test_now_is_unsupported_on_sqlite
    if ADAPTER == 'sqlite3'
      assert_raises(NotImplementedError) { User.select { now } }
    else
      assert_sql(/SELECT NOW\(\)/, User.select { now }.to_sql)
    end
  end

  # CURRENT_TIMESTAMP and its relatives are grammar rather than calls, so
  # they come out without the parentheses PostgreSQL and SQLite reject.
  def test_datetime_value_functions_are_emitted_bare
    assert_sql(/SELECT CURRENT_TIMESTAMP FROM/,
      User.select { current_timestamp }.to_sql)
    assert_sql(/SELECT CURRENT_DATE FROM/, User.select { current_date }.to_sql)
    assert_sql(/SELECT CURRENT_TIME FROM/, User.select { current_time }.to_sql)
  end

  def test_datetime_value_function_in_comparison_and_alias
    assert_sql(/WHERE "users"."name" < CURRENT_TIMESTAMP/,
      User.where { :name < current_timestamp }.to_sql)
    assert_sql(/SELECT CURRENT_TIMESTAMP AS "ts" FROM/,
      User.select { current_timestamp.as(:ts) }.to_sql)
  end

  def test_current_timestamp_runs
    User.delete_all
    User.create!(name: 'alice')
    refute_nil(User.select { current_timestamp.as(:v) }.sole.v)
  end

  # The one thing that does go into the parentheses is a precision, which
  # current_date never takes and SQLite never accepts.
  def test_datetime_value_function_with_precision
    if ADAPTER == 'sqlite3'
      e = assert_raises(NotImplementedError) { User.select { current_timestamp(3) } }
      assert_match(/precision/, e.message)
    else
      assert_sql(/SELECT CURRENT_TIMESTAMP\(3\) FROM/,
        User.select { current_timestamp(3) }.to_sql)
      assert_sql(/SELECT CURRENT_TIME\(0\) FROM/,
        User.select { current_time(0) }.to_sql)
      User.delete_all
      User.create!(name: 'alice')
      refute_nil(User.select { current_timestamp(0).as(:v) }.sole.v)
    end
  end

  def test_current_date_takes_no_precision
    assert_raises(ArgumentError) { User.select { current_date(0) } }
  end

  # The precision is written into the SQL as given, so only an Integer is
  # accepted there.
  def test_precision_must_be_an_integer
    assert_raises(ArgumentError) do
      User.select { current_timestamp(:'3); DROP TABLE users --') }
    end
  end

  def test_localtime_is_unsupported_on_sqlite
    if ADAPTER == 'sqlite3'
      assert_raises(NotImplementedError) { User.select { localtime } }
      assert_raises(NotImplementedError) { User.select { localtimestamp } }
    else
      assert_sql(/SELECT LOCALTIME FROM/, User.select { localtime }.to_sql)
      assert_sql(/SELECT LOCALTIMESTAMP FROM/,
        User.select { localtimestamp }.to_sql)
    end
  end

  def test_math_functions
    assert_sql(/SELECT SIGN\("users"."age"\)/, User.select { sign(:age) }.to_sql)
    assert_sql(/SELECT ATAN2\("users"."age", 2\)/,
      User.select { atan2(:age, 2) }.to_sql)
    assert_sql(/SELECT PI\(\)/, User.select { pi }.to_sql)
    assert_sql(/SELECT DEGREES\(RADIANS\("users"."age"\)\)/,
      User.select { degrees(radians(:age)) }.to_sql)
  end

  def test_math_functions_run
    User.delete_all
    User.create!(name: 'alice', age: 60)
    assert_equal(1, User.select { sign(:age).as(:v) }.sole.v.to_i)
    assert_equal(60,
      User.select { round(degrees(radians(:age))).as(:v) }.sole.v.to_i)
  end

  # PostgreSQL spells log2(x) as log(2, x), which no renaming carries.
  def test_log2_is_unsupported_on_postgresql
    if ADAPTER == 'postgresql'
      assert_raises(NotImplementedError) { User.select { log2(:age) } }
    else
      assert_sql(/SELECT LOG2\("users"."age"\)/, User.select { log2(:age) }.to_sql)
    end
  end

  # MySQL spells trunc TRUNCATE, and insists on the second argument the
  # others default to zero.
  def test_trunc
    expected = ADAPTER == 'mysql2' ? 'TRUNCATE' : 'TRUNC'
    assert_sql(/SELECT #{expected}\("users"."age", 0\)/,
      User.select { trunc(:age, 0) }.to_sql)
  end

  # EXTRACT(field FROM expr): the field is a keyword rather than a value.
  # SQLite spells all of this as strftime formats, which no renaming
  # carries.
  def test_extract
    if ADAPTER == 'sqlite3'
      e = assert_raises(NotImplementedError) { User.select { extract(:year, :name) } }
      assert_match(/extract/, e.message)
    else
      assert_sql(/SELECT EXTRACT\(YEAR FROM "users"."name"\)/,
        User.select { extract(:year, :name) }.to_sql)
      assert_sql(/WHERE EXTRACT\(YEAR FROM "users"."name"\) = 2026/,
        User.where { extract(:year, :name) == 2026 }.to_sql)
    end
  end

  # A bad field is an ArgumentError on every adapter, before SQLite gets to
  # say it has no extract at all.
  def test_extract_rejects_an_injected_field
    assert_raises(ArgumentError) { User.select { extract(INJECTION.to_sym, :name) } }
  end

  def test_extract_runs
    skip "#{ADAPTER} has no extract" if ADAPTER == 'sqlite3'
    User.delete_all
    User.create!(name: 'alice')
    assert_equal(2026,
      User.select { extract(:year, cast('2026-01-05', :date)).as(:v) }.sole.v.to_i)
  end

  def test_cast
    assert_sql(/SELECT CAST\("users"."age" AS text\)/,
      User.select { cast(:age, :text) }.to_sql)
  end

  def test_cast_runs
    User.delete_all
    User.create!(name: 'alice')
    assert_equal(12.5,
      User.select { cast('12.5', 'decimal(10,2)').as(:v) }.sole.v.to_f)
  end

  # The type is written into the SQL as given, so it has to look like one:
  # a plain name, at most parenthesized with lengths.  The adapters' own
  # spellings with a space in them pass too.
  def test_cast_type_names
    assert_sql(/AS double precision\)/,
      User.select { cast(:age, 'double precision') }.to_sql)
    assert_sql(/AS decimal\(10,2\)\)/,
      User.select { cast(:age, 'decimal(10,2)') }.to_sql)
    assert_raises(ArgumentError) { User.select { cast(:age, INJECTION.to_sym) } }
    assert_raises(ArgumentError) do
      User.select { cast(:age, 'integer); DROP TABLE users --') }
    end
  end

  # A name with no method of its own is still a NoMethodError, not a
  # function call the database has to reject.
  def test_unknown_function_is_a_no_method_error
    assert_raises(NoMethodError) { User.select { uppr(:name) } }
  end

  def test_arithmetic_multiplication
    assert_sql(/SELECT "users"."age" \* 2 AS "dbl"/,
      User.select { (:age * 2).as(:dbl) }.to_sql)
  end

  # Ruby puts * above >, so the expression groups the way it reads.
  def test_arithmetic_in_where_without_parentheses
    assert_sql(/WHERE "users"."age" \* 2 > 100/,
      User.where { :age * 2 > 100 }.to_sql)
  end

  def test_arithmetic_between_columns
    assert_sql(/WHERE \("users"."age" \+ "users"."id"\) \/ 2 <= 30/,
      User.where { (:age + :id) / 2 <= 30 }.to_sql)
  end

  def test_arithmetic_inside_aggregate
    assert_sql(/SELECT SUM\("users"."age" \* 2\)/,
      User.select { sum(:age * 2) }.to_sql)
  end

  def test_aggregate_on_arithmetic
    assert_sql(/SELECT SUM\(\("users"."age" \+ 1\)\) AS "s"/,
      User.select { (:age + 1).sum.as(:s) }.to_sql)
  end

  # Arel groups + and - but not * and /, which is how SQL precedence works
  # out anyway.
  def test_arithmetic_on_qualified_column
    assert_sql(/SELECT \("users"."age" - 1\)/,
      User.select { :users[:age] - 1 }.to_sql)
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
    assert_sql(/SELECT UPPER\("users"."name"\) AS "upper_name", "users"."age"/,
      User.select { [upper(:name).as(:upper_name), :age] }.to_sql)
  end

  def test_select_column_alias
    assert_sql(/SELECT "users"."name" AS "n"/,
      User.select { :name.as(:n) }.to_sql)
  end

  def test_select_qualified_column_alias
    assert_sql(/SELECT "users"."name" AS "n"/,
      User.select { :users[:name].as(:n) }.to_sql)
  end

  def test_select_aggregate_alias
    assert_sql(/SELECT COUNT\("users"."id"\) AS "cnt"/,
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

  def test_order_nulls_first
    skip_without_nulls_ordering_syntax
    assert_sql(/ORDER BY "users"."age" ASC NULLS FIRST/,
      User.order { :age.asc.nulls_first }.to_sql)
  end

  def test_order_nulls_last
    skip_without_nulls_ordering_syntax
    assert_sql(/ORDER BY "users"."age" DESC NULLS LAST, "users"."name" ASC/,
      User.order { [:age.desc.nulls_last, :name.asc] }.to_sql)
  end

  # The order itself is portable even where the syntax is not.
  def test_order_nulls_execution
    User.delete_all
    User.create!(name: 'null_age', age: nil)
    User.create!(name: 'young', age: 20)
    User.create!(name: 'old', age: 60)
    assert_equal(%w[null_age young old],
      User.order { :age.asc.nulls_first }.pluck(:name))
    assert_equal(%w[young old null_age],
      User.order { :age.asc.nulls_last }.pluck(:name))
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

  # update_all's hash reads a symbol as the value it is; the block reads it as
  # the column it names, which is what lets the new value be built from the old.
  def test_update_all_from_the_column
    Tally.delete_all
    Tally.create!(page: '/a', hits: 1)
    Tally.create!(page: '/b', hits: 2)
    Tally.update_all { { hits: :hits + 1 } }
    assert_equal([2, 3], Tally.order(:page).pluck(:hits))
  end

  def test_update_all_takes_any_expression
    Tally.delete_all
    Tally.create!(page: '/a', hits: 5)
    Tally.update_all { { hits: case_when { :hits > 4 }.then(0).else(:hits), page: upper(:page) } }
    assert_equal([['/A', 0]], Tally.pluck(:page, :hits))
  end

  def test_update_all_within_a_scope
    Tally.delete_all
    Tally.create!(page: '/a', hits: 1)
    Tally.create!(page: '/b', hits: 1)
    Tally.where { :page == '/a' }.update_all { { hits: 9 } }
    assert_equal([9, 1], Tally.order(:page).pluck(:hits))
  end

  def test_update_all_without_a_block_is_unchanged
    Tally.delete_all
    Tally.create!(page: '/a', hits: 1)
    Tally.update_all(hits: 4)
    assert_equal([4], Tally.pluck(:hits))
  end

  def test_update_all_takes_updates_or_a_block
    assert_raises(ArgumentError) { Tally.update_all({hits: 1}) { { hits: 2 } } }
    e = assert_raises(ArgumentError) { Tally.update_all { :hits + 1 } }
    assert_match(/hash of column/, e.message)
  end

  # on_duplicate takes SQL text and nothing else, so the block is compiled to
  # some.  `excluded` is the row that could not be inserted.
  def test_upsert_all_adds_to_what_is_there
    Tally.delete_all
    Tally.upsert_all([{page: '/a', hits: 1}], **upsert_target)
    Tally.upsert_all([{page: '/a', hits: 10}], **upsert_target) {
      { hits: :hits + excluded(:hits) }
    }
    assert_equal([11], Tally.pluck(:hits))
  end

  def test_upsert_all_inserts_when_there_is_no_conflict
    Tally.delete_all
    Tally.upsert_all([{page: '/new', hits: 3}], **upsert_target) {
      { hits: :hits + excluded(:hits) }
    }
    assert_equal([3], Tally.pluck(:hits))
  end

  def test_upsert_all_takes_any_expression
    Tally.delete_all
    Tally.upsert_all([{page: '/a', hits: 7}], **upsert_target)
    Tally.upsert_all([{page: '/a', hits: 2}], **upsert_target) {
      { hits: greatest(:hits, excluded(:hits)) }
    }
    assert_equal([7], Tally.pluck(:hits))
  end

  def test_upsert_all_without_a_block_is_unchanged
    Tally.delete_all
    Tally.upsert_all([{page: '/a', hits: 1}], **upsert_target)
    Tally.upsert_all([{page: '/a', hits: 6}], **upsert_target)
    assert_equal([6], Tally.pluck(:hits))
  end

  def test_upsert_all_takes_on_duplicate_or_a_block
    assert_raises(ArgumentError) do
      Tally.upsert_all([{page: '/a', hits: 1}],
                       on_duplicate: Arel.sql('hits = 1'), **upsert_target) { { hits: 2 } }
    end
    e = assert_raises(ArgumentError) do
      Tally.upsert_all([{page: '/a', hits: 1}], **upsert_target) { {} }
    end
    assert_match(/at least one column/, e.message)
  end

  # Reading inside a JSON document, by the name of what Hash does.  No two
  # adapters spell it alike, so what the tests assert is the value that comes
  # back rather than the SQL.
  def seed_docs
    Doc.delete_all
    Doc.create!(name: 'one',
                meta: json_document({ 'a' => { 'b' => 'deep' }, 'n' => 5,
                                      'tags' => %w[x y], 'odd key' => 1 }))
    Doc.create!(name: 'two', meta: json_document({ 'n' => 9 }))
  end

  def test_dig_a_key
    seed_docs
    assert_equal(%w[5 9], Doc.order(:name).select { :meta.dig(:n).as(:v) }.map(&:v))
  end

  def test_dig_a_path
    seed_docs
    assert_equal(['deep', nil],
      Doc.order(:name).select { :meta.dig(:a, :b).as(:v) }.map(&:v))
  end

  def test_dig_an_array_index
    seed_docs
    assert_equal(['x', nil],
      Doc.order(:name).select { :meta.dig(:tags, 0).as(:v) }.map(&:v))
  end

  # A key that is not a plain name travels as itself rather than being refused.
  def test_dig_a_key_that_needs_quoting
    seed_docs
    assert_equal(['1', nil],
      Doc.order(:name).select { :meta.dig(:'odd key').as(:v) }.map(&:v))
  end

  # dig gives text on every adapter -- SQLite's ->> would otherwise give the
  # value with its type -- so a number is compared through a cast.
  def test_dig_is_text_everywhere
    seed_docs
    assert_equal(['one'], Doc.where { :meta.dig(:n) == '5' }.pluck(:name))
    type = integer_type
    assert_equal(['two'], Doc.where { cast(:meta.dig(:n), type) > 6 }.pluck(:name))
  end

  def test_dig_json_keeps_the_json
    seed_docs
    value = Doc.where { :name == 'one' }.select { :meta.dig_json(:tags).as(:v) }.first.v
    assert_equal(%w[x y], value.is_a?(String) ? JSON.parse(value) : value)
  end

  def test_dig_from_a_qualified_column
    seed_docs
    assert_equal(['one'], Doc.where { :docs[:meta].dig(:a, :b) == 'deep' }.pluck(:name))
  end

  def test_key
    seed_docs
    assert_equal(['one'], Doc.where { :meta.key?(:tags) }.pluck(:name))
    assert_equal(%w[one two], Doc.where { :meta.key?(:n) }.order(:name).pluck(:name))
  end

  def test_contains
    skip_without_json_containment
    seed_docs
    assert_equal(['one'], Doc.where { :meta.contains?(n: 5) }.pluck(:name))
    assert_equal([], Doc.where { :meta.contains?(n: 1) }.pluck(:name))
  end

  def test_contains_says_where_it_cannot_go
    skip "#{ADAPTER} has JSON containment" unless ADAPTER == 'sqlite3'
    assert_raises(NotImplementedError) { Doc.where { :meta.contains?(n: 5) }.to_sql }
  end

  def test_dig_needs_a_path
    assert_raises(ArgumentError) { Doc.select { :meta.dig } }
    e = assert_raises(ArgumentError) { Doc.select { :meta.dig(1.5) } }
    assert_match(/key or an array index/, e.message)
  end

  # FILTER takes the aggregate over the rows a condition holds for.  MySQL has
  # no such clause, so what is asserted across adapters is the number that
  # comes back rather than the SQL.
  def seed_for_filter
    User.delete_all
    User.create!(name: 'a', age: 10)
    User.create!(name: 'a', age: 20)
    User.create!(name: 'b', age: 100)
  end

  def aggregate(&block)
    User.select(&block).to_a.first.v
  end

  def test_filter_a_count
    seed_for_filter
    assert_equal(2, aggregate { count(:*).filter { :age < 50 }.as(:v) }.to_i)
  end

  def test_filter_takes_a_value_as_well_as_a_block
    seed_for_filter
    assert_equal(2, aggregate { count(:*).filter(:age < 50).as(:v) }.to_i)
  end

  def test_filter_a_sum_and_an_average
    seed_for_filter
    assert_equal(30, aggregate { sum(:age).filter { :age < 50 }.as(:v) }.to_i)
    assert_equal(15, aggregate { avg(:age).filter { :age < 50 }.as(:v) }.to_i)
  end

  def test_filter_a_distinct_count
    seed_for_filter
    assert_equal(1, aggregate { count(:name, distinct: true).filter { :age < 50 }.as(:v) }.to_i)
  end

  def test_filter_on_an_aggregate_from_a_symbol
    seed_for_filter
    assert_equal(30, aggregate { :age.sum.filter { :age < 50 }.as(:v) }.to_i)
  end

  def test_filter_is_a_clause_where_there_is_one
    skip "#{ADAPTER} has no FILTER" if ADAPTER == 'mysql2'
    assert_sql(/COUNT\(\*\) FILTER \(WHERE "users"."age" < 50\)/,
      User.select { count(:*).filter { :age < 50 } }.to_sql)
  end

  # Where there is not, the same rows are reached through a case: an aggregate
  # passes over a NULL, so a row the condition misses is a row it does not see.
  def test_filter_becomes_a_case_where_there_is_no_clause
    skip "#{ADAPTER} has FILTER" unless ADAPTER == 'mysql2'
    assert_sql(/COUNT\(CASE WHEN "users"."age" < 50 THEN 1 END\)/,
      User.select { count(:*).filter { :age < 50 } }.to_sql)
    assert_sql(/SUM\(CASE WHEN "users"."age" < 50 THEN "users"."age" END\)/,
      User.select { sum(:age).filter { :age < 50 } }.to_sql)
  end

  def test_filter_needs_a_value_or_a_block
    assert_raises(ArgumentError) { User.select { count(:*).filter } }
    e = assert_raises(ArgumentError) { User.select { count(:*).filter(1) { 2 } } }
    assert_match(/not both/, e.message)
  end

  def test_default_where_syntax
    assert_sql(/WHERE "users"."name" = 'Ruby' AND "users"."age" = 19/,
      User.where(name: 'Ruby', age: 19).to_sql)
  end

  def test_value_in_a_select_list
    assert_sql(/SELECT "users"."name", 0 AS "depth"/,
      User.select { [:name, value(0).as(:depth)] }.to_sql)
  end

  # Each adapter escapes the apostrophe its own way, so what is asserted is
  # that the string stays a value rather than reaching the SQL as written.
  def test_value_is_quoted
    User.delete_all
    User.create!(name: 'alice')
    payload = "it's a value"
    assert_sql(/SELECT 'draft' AS "state"/,
      User.select { value('draft').as(:state) }.to_sql)
    assert_equal([payload],
      User.select { value(payload).as(:note) }.map(&:note))
  end

  def test_a_bare_string_is_still_sql
    assert_sql(/SELECT "users"."name", 1 \+ 1 AS two/,
      User.select { [:name, '1 + 1 AS two'] }.to_sql)
  end

  def test_value_takes_the_predications
    assert_sql(/WHERE 1 = "users"."age"/, User.where { value(1) == :users[:age] }.to_sql)
    assert_sql(/WHERE 1 IS NULL/, User.where { value(1).null? }.to_sql)
  end

  def test_value_takes_the_arithmetics
    assert_sql(/SELECT \(1 \+ "users"."age"\) AS "next_year"/,
      User.select { (value(1) + :age).as(:next_year) }.to_sql)
  end

  def test_value_as_a_function_argument
    assert_sql(/SELECT COALESCE\("users"."age", 0\)/,
      User.select { coalesce(:age, value(0)) }.to_sql)
  end

  def test_integer_shorthand_for_value
    assert_sql(/SELECT "users"."name", 0 AS "depth"/,
      User.select { [:name, 0.as(:depth)] }.to_sql)
  end

  def test_float_shorthand_for_value
    assert_sql(/SELECT 1\.5 AS "rate"/, User.select { 1.5.as(:rate) }.to_sql)
  end

  def test_numeric_shorthand_has_no_orderings
    assert_raises(NoMethodError) { User.order { 1.asc } }
    assert_raises(NoMethodError) { User.order { 1.desc } }
  end

  # The alias on a literal is quoted like any other, so a name that is not a
  # plain one arrives as itself rather than as SQL.
  def test_a_value_alias_is_quoted_rather_than_refused
    User.delete_all
    User.create!(name: 'alice')
    payload = 'a" FROM users; --'
    assert_equal(0, User.select { value(0).as(payload.to_sym) }.first[payload].to_i)
    assert_equal(0, User.select { 0.as(payload.to_sym) }.first[payload].to_i)
    assert_equal(1, User.count)
  end

  def test_a_value_selected_reaches_the_row
    User.delete_all
    User.create!(name: 'alice', age: 60)
    assert_equal([['alice', 0]],
      User.select { [:name, 0.as(:depth)] }.map {|u| [u.name, u.depth] })
  end

  def test_numeric_shorthand_is_confined_to_the_block
    assert_raises(NoMethodError) { 0.as(:depth) }
  end
end
