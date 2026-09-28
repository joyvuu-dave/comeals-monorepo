# typed: true
# frozen_string_literal: true

# `validates :start_date, storable_time: true` refuses a time the
# database cannot store (StorableTime) with a form error. Without it,
# PostgreSQL refused the time when the record was saved, and the admin
# form answered with an error page instead of the form
# (spec/requests/admin/storable_times_spec.rb). A nil value is left to
# the presence rules.
class StorableTimeValidator < ActiveModel::EachValidator
  def validate_each(record, attribute, value)
    return if value.nil? || StorableTime.timestamp?(value)

    record.errors.add(attribute, 'is not a date the database can store')
  end
end
