# typed: true
# frozen_string_literal: true

class AuditSerializer
  include Alba::Resource

  attributes :id,
             :user_name,
             :description,
             :display_time

  # The start of the comment of a row a data fix wrote with no person
  # (migration 20261010130000's TurnOffNoCostOnBillsWithAnAmount::BY).
  AUTOMATIC_FIX = 'Automatic fix'

  # A row a person made names them through `user`, and the history shows
  # their short name. A row with a username and no person shows the
  # username as it is: audited's `user` returns that text in place of a
  # record, and asking the text for a name raised, so the whole history
  # answered 500. Shortened as a person's name, it would keep only its
  # first word. A data fix writes its rows with neither, so the release
  # before this one, which still asks `user` for a name, can show them
  # after a rollback; its comment says who, and starts with AUTOMATIC_FIX.
  def user_name(audit)
    person = audit.user_as_model
    return ResidentNameShortener.short(person.name) unless person.nil?
    return audit.username.to_s if audit.username.present?

    audit.comment.to_s.start_with?(AUTOMATIC_FIX) ? AUTOMATIC_FIX : ''
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
