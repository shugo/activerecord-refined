# frozen_string_literal: true

require "active_record"
require "active_record/relation"
require "active_record/refined"

ActiveRecord::QueryMethods.prepend ActiveRecord::Refined::QueryMethods

# update_all and its kind are Relation's own rather than QueryMethods'.
ActiveRecord::Relation.prepend ActiveRecord::Refined::Writes

# The methods above are Active Record's own, so a model already forwards them
# to its relation.  These are new, and have to be added to that list.
ActiveRecord::Base.singleton_class.delegate(
  :from_cte, :distinct_on, :lateral,
  :right_outer_joins, :full_outer_joins, :cross_joins, to: :all)
