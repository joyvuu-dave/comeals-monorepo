# frozen_string_literal: true

# An event or a common house booking that ends on a later day than it
# starts. The models refuse one since #154, and so do the database's
# one-day triggers (events_one_day, common_house_reservations_one_day).
# One can still exist: when an admin changes the community's zone, a row
# that was one day in the old zone can end on a later day in the new one.
# The calendar, its cache version, the overlap check and the live updates
# must still handle it.
#
# These helpers write such a row the way insert_all writes it (no model,
# no validations, no callbacks), with the table's one-day trigger turned
# off for that one write. The database's other rules still hold (#149):
# the end is not before the start, and two bookings do not overlap.
module RowsWithoutTheModel
  def booking_without_the_model(resident:, start_date:, end_date:, title: nil)
    id = with_one_day_trigger_off(:common_house_reservations) do
      CommonHouseReservation.insert!(
        { community_id: resident.community_id, resident_id: resident.id, title: title,
          start_date: start_date, end_date: end_date },
        returning: :id
      ).first.fetch('id')
    end
    CommonHouseReservation.find(id)
  end

  def event_without_the_model(community:, start_date:, end_date:, title: 'Spanning')
    id = with_one_day_trigger_off(:events) do
      Event.insert!(
        { community_id: community.id, title: title, allday: false, start_date: start_date, end_date: end_date },
        returning: :id
      ).first.fetch('id')
    end
    Event.find(id)
  end

  # Turns the table's one-day trigger off for the block, and on again.
  # ALTER TABLE is part of the transaction, so a block that raises rolls
  # the change back with the savepoint, and the trigger is on again.
  def with_one_day_trigger_off(table)
    connection = ActiveRecord::Base.connection
    ActiveRecord::Base.transaction(requires_new: true) do
      connection.execute("ALTER TABLE #{table} DISABLE TRIGGER #{table}_one_day")
      result = yield
      connection.execute("ALTER TABLE #{table} ENABLE TRIGGER #{table}_one_day")
      result
    end
  end
end

RSpec.configure { |config| config.include RowsWithoutTheModel }
