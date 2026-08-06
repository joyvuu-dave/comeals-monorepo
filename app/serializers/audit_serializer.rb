# frozen_string_literal: true

class AuditSerializer < ActiveModel::Serializer
  include ApplicationHelper

  attributes :id,
             :user_name,
             :description,
             :display_time

  def user_name
    resident_name_helper(object.user&.name)
  end

  def description
    parse_audit(object)
  end

  def display_time
    object.created_at
  end
end
