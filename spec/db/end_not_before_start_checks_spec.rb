# frozen_string_literal: true

require 'rails_helper'

# An event or a common house booking must not end before it starts. The
# models refuse it with a sentence (start_date_is_before_end_date); these
# CHECKs make PostgreSQL refuse it from every write that skips the model:
# update_columns, update_all, insert_all, psql, and two copies of one row
# saved one after the other, one with a new start and one with a new end
# (#149).
#
# An end equal to the start is not refused here. A midnight notice ends
# when it starts, and so do four rows from before #141; the rule for that
# needs the community's zone, so it stays in the models.
RSpec.describe 'end not before start checks' do
  let(:start) { Time.zone.local(2026, 4, 12, 18, 0) }

  # Each write runs in its own savepoint: a refused statement ends the
  # transaction it runs in, and the example's transaction must go on.
  def write(record, **columns)
    record.class.transaction(requires_new: true) { record.update_columns(**columns) }
  end

  def takes?(record, **columns)
    write(record, **columns)
    true
  rescue ActiveRecord::CheckViolation
    false
  end

  it 'refuses a booking that ends before it starts, and takes one that ends when it starts' do
    booking = create(:common_house_reservation, start_date: start, end_date: start + 1.hour)

    expect do
      write(booking, end_date: start - 1.minute)
    end.to raise_error(ActiveRecord::CheckViolation, /common_house_reservations_end_not_before_start/)
    expect(takes?(booking, end_date: start)).to be(true)
  end

  it 'refuses a timed event that ends before it starts, and takes one that ends when it starts' do
    event = create(:event, start_date: start, end_date: start + 1.hour, allday: false)

    expect do
      write(event, end_date: start - 1.minute)
    end.to raise_error(ActiveRecord::CheckViolation, /events_end_not_before_start/)
    expect(takes?(event, end_date: start)).to be(true)
  end

  # All day hides the end, and an event with no end has nothing to
  # compare. The model refuses a timed event with no end in its own words
  # (end_date_or_allday).
  it 'takes an all-day event whose end is before its start, and an event with no end' do
    event = create(:event, start_date: start, end_date: start + 1.hour, allday: false)

    expect(takes?(event, allday: true, end_date: start - 1.day)).to be(true)
    expect(takes?(event, allday: false, end_date: nil)).to be(true)
    expect(takes?(event, allday: false, end_date: start - 1.day)).to be(false)
  end
end
