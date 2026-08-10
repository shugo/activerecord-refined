require 'activerecord-refined/version'
require 'active_record'
require 'active_record/relation'
require 'active_record/refined/ast'
require 'active_record/refined'

ActiveRecord::QueryMethods.prepend ActiveRecord::Refined::QueryMethods

# The methods above are ActiveRecord's own, so a model already forwards them
# to its relation.  from_cte is new, and has to be added to that list itself.
ActiveRecord::Base.singleton_class.delegate :from_cte, to: :all
