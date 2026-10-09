# frozen_string_literal: true

# A guest pays as an adult (2) or as a child (1), nothing else. Step 1 of
# 2, the way strong_migrations asks for a CHECK on a table that already
# has rows: added NOT VALID, it refuses a new guest with another price at
# once, without reading the rows already there. Step 2
# (20261009130100) checks those rows and drops the old CHECK
# guests_multiplier_non_negative, which this one makes redundant.
#
# Before this, the column took any number of 0 or more, but the admin
# meal form offers only Adult and Child. A guest with any other price
# had no matching choice, so the next save of the form sent Adult in its
# place: the host paid a full adult share and nobody was told. On a
# closed meal the same save was refused, so nothing on that meal could
# be saved from the form.
class AddGuestsMultiplierAdultOrChildCheck < ActiveRecord::Migration[8.1]
  def change
    add_check_constraint :guests, 'multiplier IN (1, 2)', name: 'guests_multiplier_adult_or_child', validate: false
  end
end
