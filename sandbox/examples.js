// Each example is a snippet the sandbox runs as-is.  `show` prints the SQL a
// relation builds and then the rows it returns; `sql` prints only the SQL.
export const examples = [
  {
    group: 'はじめに',
    items: [
      {
        title: '最初のクエリ',
        code: `# ブロックの中では、シンボルがレシーバのテーブルのカラムを指します。
show Author.where { :age >= 18 }`,
      },
      {
        title: 'ブロックの外では普通の Symbol',
        code: `# >= の意味が変わるのはブロックの中だけです。
# Symbol は Comparable を include しているので >= 自体は存在しますが、
# 18 とは比較できないので ArgumentError になります。
:age >= 18`,
      },
      {
        title: 'テーブルを修飾する',
        code: `# :table[:column] で修飾します。結合を含むクエリで効いてきます。
sql Author.where { :posts[:published] == true }`,
      },
    ],
  },

  {
    group: '条件',
    items: [
      {
        title: '比較',
        code: `show Author.where { :age >= 50 }
show Author.where { :country == 'JP' }`,
      },
      {
        title: '== nil は ArgumentError',
        code: `# SQL では country = NULL は真になりません。動くけれど1行も返らない
# クエリを書けてしまわないよう、nil はその場で弾かれます。
Author.where { :country == nil }`,
      },
      {
        title: 'NULL を探す',
        code: `show Author.where { :country.null? }
show Author.where { !:country.null? }`,
      },
      {
        title: 'NULL を値として比べる',
        code: `# != では country が NULL の行が落ちます。
show Author.where { :country != 'JP' }

# distinct_from? では残ります。SQLite では IS NOT に変換されます。
show Author.where { :country.distinct_from?('JP') }`,
      },
      {
        title: '範囲と集合',
        code: `show Author.where { :age.in?(20..50) }      # BETWEEN
show Author.where { :age.between?(20, 50) }  # 同じ
show Author.where { :age.in?(50..) }         # >= 50
show Author.where { :country.in?(%w[JP US]) } # IN`,
      },
      {
        title: 'サブクエリを in? に渡す',
        code: `# select を明示しない場合は主キーが選ばれます。
show Author.where { :id.in?(Post.published.select(:author_id)) }`,
      },
      {
        title: 'スカラサブクエリ',
        code: `# 比較の右辺に relation を置くとスカラサブクエリになります。
# 値を1つだけ選ぶ必要があるので、select は必須です。
show Author.where { :age >= Author.select { avg(:age) } }`,
      },
      {
        title: 'exists?',
        code: `show Author.where { exists?(Post.where { :posts[:author_id] == :authors[:id] }) }

# 否定は ! を付けます。
show Author.where { !exists?(Post.where { :posts[:author_id] == :authors[:id] }) }`,
      },
    ],
  },

  {
    group: '文字列マッチ',
    items: [
      {
        title: 'like?',
        code: `show Author.where { :name.like?('A%') }

# like? は PostgreSQL でも大文字小文字を区別する LIKE のままです。
# 区別しないのは ilike? と casecmp? です。
sql Author.where { :name.ilike?('a%') }
sql Author.where { :name.casecmp?('matz') }`,
      },
      {
        title: 'start_with? / end_with? / include?',
        code: `show Author.where { :name.start_with?('A') }
show Post.where { :title.include?('test') }

# like? と違い、引数はリテラル文字列として扱われます。
# % や _ はワイルドカードではなくエスケープされます。
sql Post.where { :title.include?('100%') }`,
      },
      {
        title: '複数の接頭辞',
        code: `# String の start_with? と同じく可変長引数です。どれかに当たれば真。
show Author.where { :name.start_with?('A', 'K') }`,
      },
      {
        title: '正規表現は SQLite では使えない',
        code: `# MySQL は REGEXP、PostgreSQL は ~ に変換されます。
# SQLite には対応する演算子がないので、SQL を組み立てずにその場で失敗します。
Author.where { :name =~ '^A' }`,
      },
    ],
  },

  {
    group: '組み立て',
    items: [
      {
        title: '& | ! でつなぐ',
        code: `# Ruby の演算子優先順位の都合で、比較には括弧が要ります。
show Author.where { (:age >= 18) & ((:country == 'JP') | (:country == 'US')) }
show Author.where { !:country.in?(%w[JP US]) }`,
      },
      {
        title: '算術',
        code: `show Item.where { :price * :quantity > 500 }
show Item.select { [:name, (:price * :quantity).as(:total)] }`,
      },
    ],
  },

  {
    group: '結合',
    items: [
      {
        title: 'ブロックが ON 句',
        code: `show Author.
  joins(:posts) { :posts[:author_id] == :authors[:id] }.
  where { :posts[:published] == true }.
  distinct`,
      },
      {
        title: 'left_outer_joins',
        code: `show Author.
  left_outer_joins(:posts) { :posts[:author_id] == :authors[:id] }.
  where { :posts[:id].null? }`,
      },
      {
        title: '自己結合と as:',
        code: `# as がクエリの中でのテーブル名を決めます。
# ブロックの中の修飾カラムはその名前で解決されます。
show Employee.joins(:employees, as: :managers) {
  :managers[:id] == :employees[:manager_id]
}`,
      },
    ],
  },

  {
    group: '集約と関数',
    items: [
      {
        title: 'count(:*) と DISTINCT',
        code: `sql Author.group { :country }.having { count(:*) > 1 }
sql Post.select { count(:author_id, distinct: true) }`,
      },
      {
        title: 'スカラ関数',
        code: `show Author.select { [:name, upper(:name).as(:upper_name), length(:name).as(:len)] }

# 綴りがアダプタごとに違うものは、名前を1つに揃えて変換されます。
# char_length / greatest / least は SQLite では LENGTH / MAX / MIN です。
sql Author.select { char_length(:name).as(:n) }
sql Item.select { greatest(:price, :quantity).as(:g) }`,
      },
      {
        title: '使えない関数は NotImplementedError',
        code: `# SQLite に date_trunc はありません。壊れた SQL をデータベースに
# 送りつけるのではなく、ブロックの中で失敗します。
Post.select { date_trunc('day', :created_at) }`,
      },
      {
        title: 'fn で任意の関数',
        code: `# メソッドのない関数は fn で呼べます。
sql Post.select { fn(:hex, :id).as(:h) }

# 関数名と別名は quote されず、書いたとおり SQL に出ます。
# そのため普通の識別子の形でないと ArgumentError になります。
Post.select { fn(:'evil"; DROP TABLE posts; --', 1) }`,
      },
      {
        title: '並べ替えと NULL の位置',
        code: `show Author.order { :country.asc.nulls_last }.select { [:name, :country] }`,
      },
      {
        title: '全部つなげる',
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
    group: 'CTE',
    items: [
      {
        title: 'with',
        code: `show Node.
  with(roots: Node.where { :parent_id.null? }).
  joins(:roots) { :roots[:id] == :nodes[:parent_id] }`,
      },
      {
        title: 'with_recursive でツリーを辿る',
        code: `root = Node.find_by(name: 'root')

show Node.with_recursive(
  tree: [
    Node.where { :id == root.id },
    Node.joins(:tree) { :nodes[:parent_id] == :tree[:id] },
  ]
).from(:tree, as: :nodes)`,
      },
    ],
  },

  {
    group: 'PostgreSQL 専用',
    items: [
      {
        title: '配列カラムの演算子',
        code: `# member? / superset? / subset? / intersect? は PostgreSQL の配列型
# 向けの演算子(@> <@ &&)に変換されます。
# このサンドボックスは SQLite なので、ここでは動きません。
# 生成される SQL の形だけ見てください。
sql Post.where { :title.member?('ruby') }`,
      },
    ],
  },
];
