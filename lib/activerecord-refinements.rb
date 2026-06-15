require 'activerecord-refinements/version'
require 'active_record'
require 'active_record/relation'
require 'active_record/refinements'

ActiveRecord::QueryMethods.prepend ActiveRecord::Refinements::QueryMethods
