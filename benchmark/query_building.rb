# Compares the cost of building the same queries through this gem's block
# DSL and through ActiveRecord's other argument styles: hash conditions,
# string conditions, raw Arel, and relation and/or chains.  Only query
# construction (through to_sql) is measured; every style produces the same
# SQL, which the script prints first as a sanity check.
#
# Run without bundler, so the profiling gems don't need to live in the
# Gemfile:
#
#   gem install benchmark-ips memory_profiler
#   ruby -Ilib benchmark/query_building.rb

require "benchmark/ips"
require "memory_profiler"
require "active_record"
require "activerecord-refined"

ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
ActiveRecord::Schema.verbose = false
ActiveRecord::Schema.define do
  create_table(:users) {|t| t.string :name; t.integer :age }
end

class User < ActiveRecord::Base; end

T = User.arel_table

# Each variant must generate equivalent SQL; sanity-print once.
VARIANTS = {
  "simple equality" => {
    "hash"   => -> { User.where(name: "matz").to_sql },
    "string" => -> { User.where("name = ?", "matz").to_sql },
    "arel"   => -> { User.where(T[:name].eq("matz")).to_sql },
    "block"  => -> { User.where { :name == "matz" }.to_sql },
  },
  "range (BETWEEN)" => {
    "hash"   => -> { User.where(age: 20..40).to_sql },
    "arel"   => -> { User.where(T[:age].between(20..40)).to_sql },
    "block"  => -> { User.where { :age.in?(20..40) }.to_sql },
  },
  "LIKE" => {
    "string" => -> { User.where("name LIKE ?", "ma%").to_sql },
    "arel"   => -> { User.where(T[:name].matches("ma%", nil, true)).to_sql },
    "block"  => -> { User.where { :name.like?("ma%") }.to_sql },
  },
  "compound AND/OR" => {
    "string"   => -> { User.where("age >= ? AND (name = ? OR name = ?)", 18, "matz", "nobu").to_sql },
    "arel"     => -> { User.where(T[:age].gteq(18).and(T[:name].eq("matz").or(T[:name].eq("nobu")))).to_sql },
    "relation" => -> { User.where(age: 18..).and(User.where(name: "matz").or(User.where(name: "nobu"))).to_sql },
    "block"    => -> { User.where { (:age >= 18) & ((:name == "matz") | (:name == "nobu")) }.to_sql },
  },
}

puts "=== generated SQL (sanity) ==="
VARIANTS.each do |group, variants|
  puts "--- #{group} ---"
  variants.each {|name, thunk| puts "  #{name.ljust(8)} #{thunk.call}" }
end

puts
puts "=== speed (queries built per second) ==="
VARIANTS.each do |group, variants|
  puts "--- #{group} ---"
  Benchmark.ips do |x|
    x.config(warmup: 0.5, time: 2)
    variants.each {|name, thunk| x.report(name, &thunk) }
    x.compare!
  end
end

puts
puts "=== memory (per single call) ==="
fmt = "%-18s %-9s %12s %12s"
puts format(fmt, "group", "variant", "allocated B", "objects")
VARIANTS.each do |group, variants|
  variants.each do |name, thunk|
    thunk.call # warm caches (schema, statement caches) outside the report
    report = MemoryProfiler.report { thunk.call }
    puts format(fmt, group, name, report.total_allocated_memsize, report.total_allocated)
  end
end

puts
puts "=== Proc#refined ISeq copy (memory) ==="
require "objspace"

# Proc#refined runs the block under the refinements by deep-copying its
# instruction sequence, nested blocks included.  The copy is made lazily on
# the refined proc's first call and memoized per source iseq and refinement
# list for the life of the VM, so it is paid once per block call site, not
# per query.
iseq_count = -> {
  counts = ObjectSpace.count_imemo_objects
  counts[:imemo_iseq] || counts[:iseq]
}
context = ActiveRecord::Refined::BlockContext.new
syntax = ActiveRecord::Refined::BlockSyntax

{
  "simple equality" => proc { :name == "matz" },
  "compound AND/OR" => proc { (:age >= 18) & ((:name == "matz") | (:name == "nobu")) },
}.each do |label, blk|
  refined = blk.refined(syntax)
  context.instance_exec(&refined) # the copy is made here, on the first call
  original = ObjectSpace.memsize_of(RubyVM::InstructionSequence.of(blk))
  copy = ObjectSpace.memsize_of(RubyVM::InstructionSequence.of(refined))
  puts "#{label}: original iseq #{original} B, refined copy #{copy} B"
end

make_proc = -> { proc { :age > 20 } }
context.instance_exec(&make_proc.call.refined(syntax))
before = iseq_count.call
1000.times { context.instance_exec(&make_proc.call.refined(syntax)) }
puts "1000 more calls from the same call site copied #{iseq_count.call - before} iseqs"

puts
puts "=== where the block path spends its time ==="
block = proc { :name == "matz" }
refined_block = block.refined(ActiveRecord::Refined::BlockSyntax)
context = ActiveRecord::Refined::BlockContext.new
Benchmark.ips do |x|
  x.config(warmup: 0.5, time: 2)
  x.report("Proc#refined alone") { block.refined(ActiveRecord::Refined::BlockSyntax) }
  x.report("instance_exec of pre-refined proc") { context.instance_exec(&refined_block) }
  x.report("refined + instance_exec") {
    ActiveRecord::Refined::BlockContext.new.instance_exec(&block.refined(ActiveRecord::Refined::BlockSyntax))
  }
  x.compare!
end
