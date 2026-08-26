# frozen_string_literal: true

# A build-and-connect smoke for the sqlserver adapter, run only by the
# sqlserver-probe workflow against a mcr.microsoft.com/mssql/server service.
# It is not part of the suite: it exists to learn, on real CI, whether
# tiny_tds builds on the ruby-master this gem needs, whether the adapter
# connects, and how far the DSL carries on SQL Server before any :sqlserver
# dialect exists (it resolves to the base dialect until one does).
#
# Each line prints what it learned; a raised error is itself the finding.

$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))

require "active_record"
require "tiny_tds"
require "active_record/connection_adapters/sqlserver_adapter"
puts "tiny_tds #{TinyTds::VERSION}"
puts "Active Record #{ActiveRecord::VERSION::STRING}"

config = {
  adapter: "sqlserver",
  host: ENV.fetch("SQLSERVER_HOST"),
  port: Integer(ENV.fetch("SQLSERVER_PORT")),
  username: ENV.fetch("SQLSERVER_USERNAME"),
  password: ENV.fetch("SQLSERVER_PASSWORD"),
  database: "master",
}

# SQL Server takes a while to come up, and the service has no healthcheck.
ready = false
30.times do
  begin
    ActiveRecord::Base.establish_connection(config)
    ActiveRecord::Base.connection.execute("SELECT 1")
    ready = true
    break
  rescue StandardError
    sleep 3
  end
end
raise "SQL Server did not become ready" unless ready

ActiveRecord::Base.connection.execute(
  "IF DB_ID('refined_probe') IS NULL CREATE DATABASE refined_probe")
ActiveRecord::Base.establish_connection(config.merge(database: "refined_probe"))

conn = ActiveRecord::Base.connection
puts "connected: adapter=#{conn.adapter_name} version=#{conn.database_version}"
puts "SELECT 1 => #{conn.select_value('SELECT 1')}"

require "activerecord-refined"
ActiveRecord::Migration.verbose = false
ActiveRecord::Schema.define do
  drop_table :items, if_exists: true
  create_table :items do |t|
    t.string :sku
    t.integer :price
    t.integer :quantity
  end
end

class Item < ActiveRecord::Base
end
Item.create!(sku: "A-1", price: 1200, quantity: 2)
Item.create!(sku: "B-1", price: 80, quantity: 10)

puts "dialect => #{ActiveRecord::Refined::Dialect.for(Item).class}"

where = Item.where { :price > 100 }
puts "where SQL   => #{where.to_sql}"
puts "where pluck => #{where.pluck(:sku).inspect}"

selected = Item.select { [:sku, (:price * :quantity).as(:subtotal)] }
puts "select SQL  => #{selected.to_sql}"
puts "select rows => #{selected.map { |i| [i.sku, i.subtotal] }.inspect}"

puts "OK"
