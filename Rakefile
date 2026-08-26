# frozen_string_literal: true

require "bundler/gem_tasks"
require "rake/testtask"
require "socket"

ADAPTERS = %w[sqlite3 postgresql mysql2 trilogy].freeze

# The devcontainer serves Oracle's MySQL beside MariaDB, on 3307.  A
# container from before it existed serves nothing there, and test:all says
# so rather than failing or keeping quiet.
def mysql8_reachable?
  Socket.tcp("127.0.0.1", 3307, connect_timeout: 1) { true }
rescue SystemCallError
  false
end

Rake::TestTask.new do |t|
  t.test_files = FileList["test/test_*.rb"]
end

namespace :test do
  ADAPTERS.each do |adapter|
    desc "Run the tests against #{adapter}"
    task adapter do
      puts "==== #{adapter} ===="
      ENV["ADAPTER"] = adapter
      ENV.delete("DB_PORT")
      Rake::Task[:test].reenable
      Rake::Task[:test].invoke
    end
  end

  desc "Run the tests against MySQL, which the devcontainer serves on 3307"
  task :mysql8 do
    puts "==== mysql2 (MySQL, port 3307) ===="
    ENV["ADAPTER"] = "mysql2"
    ENV["DB_PORT"] = "3307"
    Rake::Task[:test].reenable
    Rake::Task[:test].invoke
  end

  desc "Run the tests against every adapter in turn"
  task all: ADAPTERS do
    if mysql8_reachable?
      Rake::Task["test:mysql8"].invoke
    else
      puts "MySQL is not listening on 3307; skipped"
    end
  end
end

task default: :test
