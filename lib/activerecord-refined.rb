require 'activerecord-refined/version'
require 'active_record'
require 'active_record/relation'
require 'active_record/refined/ast'
require 'active_record/refined'

ActiveRecord::QueryMethods.prepend ActiveRecord::Refined::QueryMethods

# update_all and its kind are Relation's own rather than QueryMethods'.
ActiveRecord::Relation.prepend ActiveRecord::Refined::Writes

# The methods above are ActiveRecord's own, so a model already forwards them
# to its relation.  These two are new, and have to be added to that list.
ActiveRecord::Base.singleton_class.delegate :from_cte, :distinct_on, to: :all
