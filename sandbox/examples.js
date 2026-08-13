// Each example is a snippet the sandbox runs as-is.  `show` prints the SQL a
// relation builds and then the rows it returns; `sql` prints only the SQL.
//
// `slug` is what the example is called in the URL.  It is written out rather
// than made from the title so that a link goes on pointing at the same
// example when the title is reworded, and so that a long title does not make
// a long link.  Every example needs one, and no two may share; check-examples
// says so if that slips.
export const examples = [
  {
    group: 'Getting started',
    items: [
      {
        title: 'A first query',
        slug: 'first-query',
        code: `# Inside the block, a symbol is a column of the receiver's table.
show Author.where { :age >= 18 }`,
      },
      {
        title: 'Outside a block it is a plain Symbol',
        slug: 'plain-symbol',
        code: `# >= only means something else inside the block.  Symbol includes
# Comparable, so >= exists, but it cannot compare itself to 18.
:age >= 18`,
      },
      {
        title: 'Qualifying the table',
        slug: 'qualifying',
        code: `# :table[:column] qualifies.  This is what joins are written with.
sql Author.where { :posts[:published] == true }`,
      },
    ],
  },

  {
    group: 'Conditions',
    items: [
      {
        title: 'Comparisons',
        slug: 'comparisons',
        code: `show Author.where { :age >= 50 }
show Author.where { :country == 'JP' }`,
      },
      {
        title: '== nil raises',
        slug: 'nil-raises',
        code: `# country = NULL is never true in SQL.  Letting nil through would mean
# a query that runs and returns nothing, so it is refused here instead.
Author.where { :country == nil }`,
      },
      {
        title: 'Looking for NULL',
        slug: 'null',
        code: `show Author.where { :country.null? }
show Author.where { :country.not_null? }

# ! negates anything.  The methods above are for the negations SQL spells
# for itself, and pick the same rows as writing NOT around the positive.
sql Author.where { !:country.null? }`,
      },
      {
        title: 'Comparing NULL as a value',
        slug: 'null-as-value',
        code: `# != drops the rows where country is NULL.
show Author.where { :country != 'JP' }

# distinct_from? keeps them.  On SQLite this becomes IS NOT.
show Author.where { :country.distinct_from?('JP') }`,
      },
      {
        title: 'Ranges and sets',
        slug: 'ranges',
        code: `show Author.where { :age.in?(20..50) }        # BETWEEN
show Author.where { :age.between?(20, 50) }   # the same
show Author.where { :age.in?(50..) }          # >= 50
show Author.where { :country.in?(%w[JP US]) } # IN

# Each has its negative.  This one comes back empty, which is SQL rather
# than the DSL: the authors left are the ones whose country is NULL, and
# NULL NOT IN (...) is unknown rather than true, so they are dropped.
# ! around in? does the same.  distinct_from? is what keeps them.
show Author.where { :country.not_in?(%w[JP US]) }

# not_between? is the one whose SQL does not look like its name: Arel
# writes it as the two comparisons.
show Author.where { :age.not_between?(20, 50) }`,
      },
      {
        title: 'A relation as a subquery',
        slug: 'subquery',
        code: `# Without an explicit select list the primary key is selected.
show Author.where { :id.in?(Post.published.select(:author_id)) }`,
      },
      {
        title: 'Scalar subqueries',
        slug: 'scalar-subquery',
        code: `# A relation on the right of a comparison is a scalar subquery.  It has
# to select one value, so a select list is required.
show Author.where { :age >= Author.select { avg(:age) } }`,
      },
      {
        title: 'exists?',
        slug: 'exists',
        code: `show Author.where { exists?(Post.where { :posts[:author_id] == :authors[:id] }) }

# Negate it with !.
show Author.where { !exists?(Post.where { :posts[:author_id] == :authors[:id] }) }`,
      },
    ],
  },

  {
    group: 'Matching strings',
    items: [
      {
        title: 'like?',
        slug: 'like',
        code: `show Author.where { :name.like?('A%') }

# like? is case-sensitive LIKE on every adapter, PostgreSQL included.
# ilike? and casecmp? are the ones that are not.
sql Author.where { :name.ilike?('a%') }
sql Author.where { :name.casecmp?('alice') }

# not_like? and not_ilike? are the negatives.
show Author.where { :name.not_like?('A%') }`,
      },
      {
        title: 'start_with? / end_with? / include?',
        slug: 'start-end-include',
        code: `show Author.where { :name.start_with?('A') }
show Post.where { :title.include?('test') }

# Unlike like?, the argument is a literal string: % and _ in it are
# escaped rather than matched as wildcards.
sql Post.where { :title.include?('100%') }`,
      },
      {
        title: 'Several prefixes',
        slug: 'prefixes',
        code: `# Variadic, like String#start_with?.  Matching any one of them is enough.
show Author.where { :name.start_with?('A', 'B') }`,
      },
      {
        title: 'Regexps are not available on SQLite',
        slug: 'regexp',
        code: `# REGEXP on MySQL, ~ on PostgreSQL.  SQLite has no operator of its
# own, so no SQL can be built for this -- unlike the checks the block
# makes as you write it, this one comes from Arel at to_sql.
sql Author.where { :name =~ '^A' }`,
      },
    ],
  },

  {
    group: 'Putting conditions together',
    items: [
      {
        title: '& | !',
        slug: 'and-or-not',
        code: `# Ruby's operator precedence is what makes the parentheses necessary.
show Author.where { (:age >= 18) & ((:country == 'JP') | (:country == 'US')) }
show Author.where { !:country.in?(%w[JP US]) }`,
      },
    ],
  },

  {
    group: 'Expressions',
    items: [
      {
        title: 'Arithmetic',
        slug: 'arithmetic',
        code: `show Item.where { :price * :quantity > 500 }
show Item.select { [:name, (:price * :quantity).as(:total)] }`,
      },
      {
        title: 'CASE',
        slug: 'case',
        code: `# Two shapes: an operand to compare each when against, or a condition on
# every when.  \`case\` is a Ruby keyword, so the method behind both needs
# the receiver -- self.case -- and each shape has a shorthand that does not.
show Author.select { [:name, :country.when('JP').then('Japan').else('elsewhere').as(:place)] }

show Author.select {
  [
    :name,
    case_when { :age < 18 }.then('minor').
      when { :age >= 50 }.then('senior').
      else('adult').as(:band),
  ]
}

# A when takes a value or a block, and so do then and else.  It is an
# expression like any other, so it goes inside an aggregate too.
show Author.select { sum(case_when { :age >= 50 }.then(1).else(0)).as(:seniors) }`,
      },
    ],
  },

  {
    group: 'Joins',
    items: [
      {
        title: 'The block is the ON clause',
        slug: 'join-on',
        code: `show Author.
  joins(:posts) { :posts[:author_id] == :authors[:id] }.
  where { :posts[:published] == true }.
  distinct`,
      },
      {
        title: 'left_outer_joins',
        slug: 'left-outer-join',
        code: `show Author.
  left_outer_joins(:posts) { :posts[:author_id] == :authors[:id] }.
  where { :posts[:id].null? }`,
      },
      {
        title: 'Self joins and as:',
        slug: 'self-join',
        code: `# as names the table within the query, and the qualified columns in the
# block go by that name.
show Employee.joins(:employees, as: :managers) {
  :managers[:id] == :employees[:manager_id]
}`,
      },
    ],
  },

  {
    group: 'Aggregates and functions',
    items: [
      {
        title: 'count(:*) and DISTINCT',
        slug: 'count',
        code: `sql Author.group { :country }.having { count(:*) > 1 }
sql Post.select { count(:author_id, distinct: true) }`,
      },
      {
        title: 'Scalar functions',
        slug: 'functions',
        code: `show Author.select { [:name, upper(:name).as(:upper_name), length(:name).as(:len)] }

# Where the spelling differs by adapter, the method names one meaning and
# each adapter gets its own: char_length, greatest and least are LENGTH,
# MAX and MIN on SQLite.
sql Author.select { char_length(:name).as(:n) }
sql Item.select { greatest(:price, :quantity).as(:g) }`,
      },
      {
        title: 'A function an adapter lacks raises',
        slug: 'missing-function',
        code: `# SQLite has no date_trunc.  The block fails rather than leaving the
# database to reject the SQL.
Post.select { date_trunc('day', :created_at) }`,
      },
      {
        title: 'fn reaches any function',
        slug: 'fn',
        code: `# Functions without a method of their own go through fn.
sql Post.select { fn(:hex, :id).as(:h) }

# A function name and a column alias are written into the SQL as given,
# not quoted, so they have to be plain names.
Post.select { fn(:'evil"; DROP TABLE posts; --', 1) }`,
      },
      {
        title: 'Window functions',
        slug: 'over',
        code: `# over gives a function a window.  It is built by chaining, the way Arel's
# own is: partition, order, and a frame.
show Author.select {
  [
    :name,
    :country,
    avg(:age).over.partition(:country).as(:country_average),
    row_number.over.partition(:country).order(:age.desc).as(:rank),
  ]
}

# A frame is a range of rows counted from the current one: negative before
# it, positive after, 0 the row itself, an open end for unbounded.  ..0 is
# what a running total wants.
show Post.select { [:title, :likes, sum(:likes).over.order(:id).rows(..0).as(:running)] }

# row_number and its kind say nothing without a window, and say so.
Author.select { row_number.as(:r) }`,
      },
      {
        title: 'Ordering, and where NULLs go',
        slug: 'order',
        code: `show Author.order { :country.asc.nulls_last }.select { [:name, :country] }`,
      },
      {
        title: 'All of it at once',
        slug: 'all-at-once',
        code: `show Author.
  joins(:posts) { :posts[:author_id] == :authors[:id] }.
  where { :posts[:published] == true }.
  group { :authors[:id] }.
  having { count(:posts[:id]) > 1 }.
  order { count(:posts[:id]).desc }.
  select {
    [
      upper(:authors[:name]).as(:author),
      count(:posts[:id]).as(:post_count),
      avg(:posts[:likes]).as(:avg_likes),
    ]
  }`,
      },
    ],
  },

  {
    group: 'JSON',
    items: [
      {
        title: 'dig',
        slug: 'dig',
        code: `# dig reads inside a JSON document, by the name of what Hash does.  A
# string or symbol steps into an object, an integer into an array.
show Doc.select { [:name, :meta.dig(:author, :name).as(:author), :meta.dig(:tags, 0).as(:first_tag)] }

# dig gives text on every adapter, so a number is compared through a cast.
show Doc.where { cast(:meta.dig(:stars), 'integer') > 6 }`,
      },
      {
        title: 'has_key? and contains?',
        slug: 'has-key',
        code: `show Doc.where { :meta.has_key?(:author) }

# No two adapters spell any of this alike; the block is the same on all
# three.  Containment is the exception -- SQLite has none, so this page
# cannot run it.
Doc.where { :meta.contains?(stars: 5) }`,
      },
    ],
  },

  {
    group: 'Writing',
    items: [
      {
        title: 'update_all',
        slug: 'update-all',
        code: `# update_all's hash reads a symbol as the value it is.  The block reads it
# as the column it names, which is what lets the new value be worked out
# from the old.
show Post.where { :published == true }

Post.where { :published == true }.update_all { { likes: :likes + 1 } }
show Post.where { :published == true }`,
      },
      {
        title: 'upsert_all',
        slug: 'upsert-all',
        code: `# The block says what happens to a row that is already there.
# excluded is the row that could not be inserted.  PostgreSQL and SQLite
# name it; MySQL spells the same thing VALUES(column).
Author.upsert_all([{ id: 1, name: 'Alice', country: 'JP', age: 38 }],
                  unique_by: :id) { { age: :age + excluded(:age) } }

show Author.where { :name == 'Alice' }`,
      },
    ],
  },

  {
    group: 'Common table expressions',
    items: [
      {
        title: 'with',
        slug: 'with',
        code: `show Node.
  with(roots: Node.where { :parent_id.null? }).
  joins(:roots) { :roots[:id] == :nodes[:parent_id] }`,
      },
      {
        title: 'Walking a tree with with_recursive',
        slug: 'with-recursive',
        code: `root = Node.find_by(name: 'root')

show Node.with_recursive(
  tree: [
    Node.where { :id == root.id },
    Node.joins(:tree) { :nodes[:parent_id] == :tree[:id] },
  ]
).from_cte(:tree)`,
      },
      {
        title: 'Carrying the root and the depth down',
        slug: 'root-and-depth',
        code: `# The anchor takes every root and the recursive member carries what it
# started with down to each child, so one walk covers the whole forest and
# every row knows which tree it came from and how far down it sits.  Which
# tree you want is an ordinary where, asked afterwards -- the CTE is not
# rebuilt for each root, which is what makes it worth naming.
#
# 0 is a value rather than SQL: at the top of a select list a bare string
# would be SQL, so numbers say .as directly and anything else says
# value(...).as.
forest = Node.with_recursive(
  tree: [
    Node.where { :parent_id.null? }.
      select { [:id, :name, :parent_id, :id.as(:root_id), 0.as(:depth)] },
    Node.joins(:tree) { :nodes[:parent_id] == :tree[:id] }.
      select { [:id, :name, :parent_id,
                :tree[:root_id], (:tree[:depth] + 1).as(:depth)] },
  ]
).from_cte(:tree).order { [:depth, :id] }

show forest

# from_cte selects the CTE as nodes, which is what lets this where find its
# column: without that alias the SQL would say nodes.root_id of a table the
# query no longer has.
root = Node.find_by(name: 'other root')
show forest.where { :root_id == root.id }`,
      },
    ],
  },

  {
    group: 'PostgreSQL only',
    items: [
      {
        title: 'Array column operators',
        slug: 'arrays',
        code: `# member?, superset?, subset? and intersect? become PostgreSQL's array
# operators (@> <@ &&).  This sandbox is on SQLite, so they do not run
# here -- only the shape of the SQL is worth looking at.
sql Post.where { :title.member?('ruby') }`,
      },
    ],
  },
];
