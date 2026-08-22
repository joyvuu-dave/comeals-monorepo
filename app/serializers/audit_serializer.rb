# frozen_string_literal: true

class AuditSerializer
  include Alba::Resource

  attributes :id,
             :user_name,
             :description,
             :display_time

  def user_name(audit)
    ResidentNameShortener.short(audit.user&.name)
  end

  def description(audit)
    AuditDescription.describe(audit)
  end

  def display_time(audit)
    audit.created_at
  end
end
