# typed: true
# frozen_string_literal: true

class ApplicationRecord < ActiveRecord::Base
  primary_abstract_class

  # No admin filter or sort may reach through an association unless the
  # model names it (Bill names meal and resident). Ransack asks for this
  # list when a filter or sort key is not one of the model's own columns,
  # and raises when a model has no list, so a hand-typed key like
  # q[s]=unknown+asc would be a 500 instead of being ignored.
  def self.ransackable_associations(_auth_object = nil)
    []
  end
end
