require 'activerecord-refined/version'
require 'active_record'
require 'active_record/relation'
require 'active_record/refined/ast'
require 'active_record/refined'

ActiveRecord::QueryMethods.prepend ActiveRecord::Refined::QueryMethods
