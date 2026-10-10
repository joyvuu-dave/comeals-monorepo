# frozen_string_literal: true

# An event or a common house booking must not end before it starts
# (#149). Step 1 of 2, the way strong_migrations asks for a CHECK on a
# table that already has rows: added NOT VALID, each CHECK refuses a new
# row that ends before it starts at once, without reading the rows
# already there. Step 2 (20261009171600) checks those rows.
#
# Before this only the models checked it (start_date_is_before_end_date).
# A write that skips the model could store such a row: update_all,
# insert_all, psql, or two copies of one row saved one after the other,
# one with a new start and one with a new end.
#
# An end equal to the start is allowed here. A midnight notice ends when
# it starts, and so do four rows from before #141. The rule for that
# needs the community's zone, which a CHECK cannot read, so it stays in
# the models. An all-day event's end does not count, and a timed event
# with no end is refused by the model (end_date_or_allday).
class AddEndNotBeforeStartChecks < ActiveRecord::Migration[8.1]
  def change
    add_check_constraint :common_house_reservations, 'end_date >= start_date',
                         name: 'common_house_reservations_end_not_before_start', validate: false
    add_check_constraint :events, 'allday OR end_date IS NULL OR end_date >= start_date',
                         name: 'events_end_not_before_start', validate: false
  end
end
