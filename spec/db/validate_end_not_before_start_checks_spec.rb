# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('db/migrate/20261009171600_validate_end_not_before_start_checks.rb')

# The migration that checks every event and booking already in the tables
# against the end-not-before-start CHECKs refuses to run while a row ends
# before it starts, and names each one with its times in the community's
# zone, the way admin shows them. Without the guard the release would
# fail with a message about a constraint, and the person deploying would
# have to find the rows by hand.
RSpec.describe ValidateEndNotBeforeStartChecks do
  let(:connection) { ActiveRecord::Base.connection }
  let(:start) { Time.zone.local(2026, 4, 12, 18, 0) }

  # suppress_messages keeps the migration's "-- select_rows ..." lines
  # out of the RSpec output.
  def refuse_rows_that_end_before_they_start!
    migration = described_class.new
    migration.suppress_messages { migration.send(:refuse_rows_that_end_before_they_start) }
  end

  it 'passes when every row ends when or after it starts' do
    create(:common_house_reservation, start_date: start, end_date: start + 1.hour)
    create(:event, start_date: start, end_date: start + 1.hour, allday: false).update_columns(end_date: start)
    create(:event, start_date: start, end_date: nil, allday: true)

    expect { refuse_rows_that_end_before_they_start! }.not_to raise_error
  end

  it 'refuses, naming each row and its times, when rows end before they start' do
    booking = create(:common_house_reservation, start_date: start, end_date: start + 1.hour)
    event = create(:event, start_date: start + 2.hours, end_date: start + 3.hours, allday: false)
    all_day = create(:event, start_date: start, end_date: start + 1.hour, allday: false)
    # The CHECKs forbid these rows, and so does the EXCLUDE's range for a
    # booking, so drop them for this example (rolled back with the
    # transaction) and write the rows the way raw SQL would.
    connection.remove_check_constraint(:common_house_reservations,
                                       name: 'common_house_reservations_end_not_before_start')
    connection.remove_exclusion_constraint(:common_house_reservations, name: 'common_house_reservations_no_overlap')
    connection.remove_check_constraint(:events, name: 'events_end_not_before_start')
    booking.update_columns(end_date: start - 1.minute)
    event.update_columns(end_date: start + 1.hour)
    all_day.update_columns(allday: true, end_date: start - 1.day)

    expect { refuse_rows_that_end_before_they_start! }.to raise_error(
      RuntimeError,
      "2 row(s) end before they start: common house booking #{booking.id} (2026-04-12 18:00 to 2026-04-12 17:59), " \
      "event #{event.id} (2026-04-12 20:00 to 2026-04-12 19:00). Times are in America/Los_Angeles. " \
      'Fix each one, then run this migration again.'
    )
  end
end
