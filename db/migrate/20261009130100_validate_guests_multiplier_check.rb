# frozen_string_literal: true

# A guest pays as an adult (2) or as a child (1). Step 2 of 2: check the
# guests already in the table against the CHECK from step 1, then drop
# guests_multiplier_non_negative, because "1 or 2" already says "not
# below 0".
#
# The production copy of 2026-09-09 has 984 guests, and every one is 2.
# Nothing in the app makes another price: the API makes every guest with
# the column default, 2, and the admin form offers only 2 and 1. If a
# guest with another price appears before this runs (only the console
# can make one), the migration stops and lists each one
# (refuse_guests_with_another_price), so the release fails and the old
# release keeps serving. Step 1's CHECK is already committed by then,
# which refuses only what the old release never writes. A guest on a
# settled meal cannot be changed by the app; see
# docs/runbooks/settled-data-repair.md.
#
# Rollback to v613 (2146821) as code only is safe: v613 writes guests
# the same way, with 2 from the API and 2 or 1 from the admin form.
class ValidateGuestsMultiplierCheck < ActiveRecord::Migration[8.1]
  def up
    refuse_guests_with_another_price
    validate_check_constraint :guests, name: 'guests_multiplier_adult_or_child'
    remove_check_constraint :guests, name: 'guests_multiplier_non_negative'
  end

  def down
    # safety_assured: strong_migrations wants a CHECK added unvalidated
    # and validated in a second migration, to avoid a long lock on a big
    # table. guests has about a thousand rows, and every one of them is 1
    # or 2 here, so the check passes at once.
    safety_assured do
      add_check_constraint :guests, 'multiplier >= 0', name: 'guests_multiplier_non_negative'
    end
  end

  private

  # The validation would fail on such a row anyway, but with a message
  # about a constraint. This one names each guest, its meal's date and its
  # price, so the person deploying knows which ones to fix.
  def refuse_guests_with_another_price
    rows = select_rows(<<~SQL.squish)
      SELECT guests.id, meals.date, guests.multiplier
      FROM guests JOIN meals ON meals.id = guests.meal_id
      WHERE guests.multiplier NOT IN (1, 2)
      ORDER BY meals.date, guests.id
    SQL
    return if rows.empty?

    list = rows.map { |id, date, multiplier| "guest #{id} on #{date} (#{multiplier})" }
    raise "#{rows.size} guest(s) have a price that is not 2 (Adult) or 1 (Child): #{list.join(', ')}. " \
          'Give each one 2 or 1, then run this migration again.'
  end
end
