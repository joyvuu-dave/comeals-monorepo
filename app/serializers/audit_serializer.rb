# typed: true
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
    describer.describe(audit)
  end

  def display_time(audit)
    audit.created_at
  end

  private

  # One describer for the whole list, built on the first row: its
  # lookups then run once for every row instead of once per row (#84).
  def describer
    @describer ||= AuditDescription.for(object.is_a?(Enumerable) ? object : [object])
  end
end
