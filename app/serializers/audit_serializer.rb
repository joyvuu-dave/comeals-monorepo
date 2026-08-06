# frozen_string_literal: true

class AuditSerializer < ActiveModel::Serializer
  attributes :id,
             :user_name,
             :description,
             :display_time

  def user_name
    ResidentNameShortener.short(object.user&.name)
  end

  def description
    AuditDescription.describe(object)
  end

  def display_time
    object.created_at
  end
end
