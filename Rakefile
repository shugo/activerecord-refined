require "bundler/gem_tasks"
require "rake/testtask"

ADAPTERS = %w[sqlite3 postgresql mysql2].freeze

Rake::TestTask.new do |t|
  t.test_files = FileList['test/test_*.rb']
end

namespace :test do
  ADAPTERS.each do |adapter|
    desc "Run the tests against #{adapter}"
    task adapter do
      puts "==== #{adapter} ===="
      ENV['ADAPTER'] = adapter
      Rake::Task[:test].reenable
      Rake::Task[:test].invoke
    end
  end

  desc "Run the tests against every adapter in turn"
  task all: ADAPTERS
end

task default: :test
