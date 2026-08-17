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
        title: 'IS TRUE and IS FALSE',
        slug: 'is-true',
        code: `show Post.where { :published.true? }

# Nobody has said either way about the last post, and published = TRUE is
# itself NULL there rather than false.  So it is the negations that tell
# the two apart: not_true? has that row and !(== true) does not.
show Post.where { :published.not_true? }
show Post.where { !(:published == true) }

# false? and not_false? are the other two.
show Post.where { :published.false? }`,
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
show Item.select { [:name, (:price * :quantity).as(:total)] }

# The number may stand on the left; plain Ruby arithmetic is untouched.
show Item.select { [:name, (12 - :quantity).as(:to_the_dozen)] }`,
      },
      {
        title: 'Bitwise operators',
        slug: 'bitwise',
        code: `# & | ^ ~ << >> are SQL's bit operations here.  Between conditions & and
# | are AND and OR, which is what leaves them free on a column.  flags is
# 1 comments open, 2 pinned, 4 featured.
show Post.select { [:title, :flags, (:flags & 4).as(:featured)] }

# SQLite has no XOR at all, so it gets the two operations XOR is made of.
# PostgreSQL would say #, MySQL ^ -- and each is wrong on the other.
show Post.select { [:title, (:flags ^ 1).as(:toggled)] }

# A boolean column is refused: two adapters would answer as AND does and
# PostgreSQL has no such operator, so one block would mean two things.
Post.where { :published & :published }`,
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
      {
        title: 'The joins Active Record has no method for',
        slug: 'other-joins',
        code: `# RIGHT OUTER keeps the rows of the table joined rather than the one
# selected from -- here, the comment whose post has gone.
Comment.find_or_create_by!(post_id: 999, body: 'orphan')

show Post.right_outer_joins(:comments) { :comments[:post_id] == :posts[:id] }.
  select { [:posts[:title], :comments[:body]] }

# FULL OUTER keeps both sides.  MySQL has no spelling for it, and the gem
# says so rather than leaving MySQL's parser to; SQLite has had one since
# 3.39 and PostgreSQL always.
show Post.full_outer_joins(:comments) { :comments[:post_id] == :posts[:id] }.
  select { [:posts[:title], :comments[:body]] }

# CROSS JOIN is every row against every row, so there is no condition to
# give and no block to write it in.  Every employee against every post:
# the review roster before anyone has picked.
show Employee.cross_joins(:posts).select { [:employees[:name], :posts[:title]] }`,
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
        title: 'filter',
        slug: 'filter',
        code: `# filter takes the aggregate over the rows a condition holds for.
show Author.select {
  [
    count(:*).as(:authors),
    count(:*).filter { :age < 50 }.as(:under_50),
    avg(:age).filter { :country == 'JP' }.as(:jp_average),
  ]
}

# MySQL has no FILTER clause and gets the case that means the same thing.
# This page is on SQLite, which has one.
sql Author.select { count(:*).filter { :age < 50 } }`,
      },
      {
        title: 'Scalar functions',
        slug: 'functions',
        code: `show Author.select { [:name, upper(:name).as(:upper_name), length(:name).as(:len)] }

# Where the spelling differs by adapter, the method names one meaning and
# each adapter gets its own: char_length, greatest and least are LENGTH,
# MAX and MIN on SQLite.
sql Author.select { char_length(:name).as(:n) }
sql Item.select { greatest(20 - :quantity, 0).as(:shortfall) }`,
      },
      {
        title: 'A function an adapter lacks raises',
        slug: 'missing-function',
        code: `# SQLite has no date_trunc.  The block fails rather than leaving the
# database to reject the SQL -- on PostgreSQL, where the function is,
# there is nothing to refuse and the same line builds.
sql Post.select { date_trunc('day', :created_at) }`,
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
        title: 'One row per group',
        slug: 'row-number-per-group',
        code: `# The oldest author of each country: number the rows within each group
# and keep the first.  This is what PostgreSQL's DISTINCT ON says in one
# clause, and it runs everywhere.
#
# The subquery is named after the model's own table for the reason from_cte
# is: Active Record goes on qualifying columns with it.
ranked = Author.select {
  [:name, :country, :age, row_number.over.partition(:country).order(:age.desc).as(:rn)]
}

show Author.from(ranked, :authors).where { :rn == 1 }.order { :country }`,
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
        code: `# dig reads inside a JSON document, by the name of what Hash does, and
# what it finds stays JSON -- the author object comes back whole.  A
# string or symbol steps into an object, an integer into an array.
show Doc.select { [:name, :meta.dig(:author).as(:author),
  :meta.dig(:tags, 0).as(:first_tag), :meta.dig(:stars).as(:stars)] }

# dig_text gives the value as text instead, which is what a comparison
# wants.
show Doc.select { [:name, :meta.dig_text(:author, :name).as(:author),
  :meta.dig_text(:tags, 0).as(:first_tag), :meta.dig_text(:stars).as(:stars)] }

# dig_text gives text on every adapter, so a number is compared through
# a cast.
show Doc.where { cast(:meta.dig_text(:stars), 'integer') > 6 }

# Comparing it with a number instead is refused: the three adapters
# answer that three ways -- true here, an error on PostgreSQL, true on
# MySQL -- and cast is what says which type was meant.
show Doc.where { :meta.dig_text(:stars) > 6 }`,
      },
      {
        title: 'bury and except',
        slug: 'bury',
        code: `# bury sets what dig reads: the last argument is the value, the rest are
# the path to it.  The document comes back changed rather than being
# written anywhere, so update_all is what makes it stick.
show Doc.select { [:name, :meta.dig_text(:author, :name).as(:author)] }

Doc.where { :name == 'first' }.update_all { { meta: :meta.bury(:author, :name, 'Erin') } }

show Doc.select { [:name, :meta.dig_text(:author, :name).as(:author)] }

# except takes keys out again, as Hash#except does -- keys of the
# document, however many, rather than a path.  It gives back a document
# too, so review sign-off is one statement: mark it reviewed, drop the
# draft flag.
Doc.where { :name == 'second' }.
  update_all { { meta: :meta.bury(:reviewed, true).except(:draft) } }

show Doc.where { :name == 'second' }`,
      },
      {
        title: 'key? and contains?',
        slug: 'key',
        code: `show Doc.where { :meta.key?(:author) }

# What dig keeps is a document, so these read it too: the same
# question asked of a part rather than of the whole.
show Doc.where { :meta.dig(:author).key?(:name) }

# No two adapters spell any of this alike; the block is the same on all
# three.  Containment is the exception -- SQLite has none, so this page
# cannot run it unless the database above is PostgreSQL.
show Doc.where { :meta.contains?(stars: 5) }
show Doc.where { :meta.dig(:tags).contains?(['sql']) }`,
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
# from the old.  It has no relation to show -- it runs and answers with a
# count -- so the statement is printed as it goes, between the two reads.
show Post.where { :published == true }

Post.where { :published == true }.update_all { { likes: :likes + 1 } }
show Post.where { :published == true }`,
      },
      {
        title: 'upsert_all',
        slug: 'upsert-all',
        code: `# A delivery arrives: some of it is stock we carry, some of it is new.
# upsert_all takes the lot in one statement, and the block says what
# happens to the rows already there -- where excluded is the row that
# could not be inserted.  PostgreSQL and SQLite name it that; MySQL
# spells the same thing VALUES(column).
show Item.order(:name)

delivery = [
  { name: 'Keyboard', price: 130, quantity: 2 },
  { name: 'Mouse',    price: 25,  quantity: 10 },
]

# The new price is taken as it comes; the quantity is added to what is on
# the shelf.  Anything the block does not name is left alone, which is
# what keeps this from overwriting a row with the half of it we were sent.
Item.upsert_all(delivery, unique_by: :name) {
  { price: excluded(:price), quantity: :quantity + excluded(:quantity) }
}

show Item.order(:name)`,
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
        title: 'Regular expressions',
        slug: 'regexp',
        code: `# =~ and !~ become ~ and !~ on PostgreSQL, REGEXP on MySQL.  SQLite has
# no regexp operator of its own, and the refusal comes from Arel as the
# SQL is written rather than from the block as it is read.
show Author.where { :name =~ '^A' }

# A Regexp literal reads more naturally, and !~ is the negative.  Only
# the source of it crosses over: the database has its own dialect and
# no notion of Ruby's flags, so a literal carrying one is refused.
show Post.where { :title !~ /notes$/ }`,
      },
      {
        title: 'distinct_on',
        slug: 'distinct-on',
        code: `# distinct_on is PostgreSQL's DISTINCT ON: the first row of each group
# the order brings up, which is why the order has to start with what the
# distinct is on.  Arel refuses to write it for the others, so on SQLite
# this says so rather than running.  Switch the database above to see it
# run.
show Author.distinct_on { :country }.order { [:country, :age.desc] }`,
      },
      {
        title: 'grouping_sets, rollup and cube',
        slug: 'grouping-sets',
        code: `# More than one grouping in a single query, the totals of each coming
# back beside the rows.  An empty set is the grand total.  MySQL has only
# WITH ROLLUP, which is a clause of its own, and SQLite has none of it.
show Post.group { grouping_sets([:author_id], [:published], []) }.
  select { [:author_id, :published, count(:*).as(:posts)] }`,
      },
      {
        title: 'lateral',
        slug: 'lateral',
        code: `# A lateral join lets the relation joined see the row being joined to,
# which is what makes the top row of each group reachable in one query.
# PostgreSQL has it and so has MySQL 8; SQLite has neither.
top_post = Post.select { :title }.
  where { :posts[:author_id] == :authors[:id] }.
  order { :likes.desc }.limit(1)

show Author.left_outer_joins(top_post.lateral, as: :top).
  select { [:name, :top[:title].as(:top_post)] }`,
      },
      {
        title: 'any and all',
        slug: 'quantifiers',
        code: `# ANY and ALL quantify a comparison over a subquery: > any is greater
# than the smallest row it returns, >= all than every one.  PostgreSQL
# and MySQL have both; SQLite has neither, and the gem says so rather
# than leaving SQLite's parser to.
show Author.where { :age > any(Author.where { :country == 'JP' }.select(:age)) }`,
      },
      {
        title: 'The bit aggregates',
        slug: 'bit-aggregates',
        code: `# bit_and, bit_or and bit_xor aggregate the bitwise operators over a
# group, and bit_count counts the bits that are set.  PostgreSQL and
# MySQL have all four; SQLite has none.
show Post.select { [bit_and(:flags).as(:common), bit_or(:flags).as(:any)] }`,
      },
      {
        title: 'Array column operators',
        slug: 'arrays',
        code: `# member?, superset?, subset? and intersect? become PostgreSQL's array
# operators (@> <@ &&).  An array is a column type there and nowhere
# else, so posts has tags only on PostgreSQL: on SQLite there is nothing
# for this to ask about.
show Post.where { :tags.member?('ruby') }
show Post.where { :tags.intersect?(%w[jit release]) }`,
      },
    ],
  },
];
