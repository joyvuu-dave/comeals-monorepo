# frozen_string_literal: true

# ADR 0011 rule 7: each settlement line saves the person's unit, and
# whether they lived here, on the day the settlement is made. The unit
# totals on a settlement page come from those saved values, so they never
# change later, and the people who had moved out are counted on their
# own. reconciliations.units_recorded_on is the day the units of a
# settlement's lines were saved.
#
# The app kept no history of anyone's unit, so the lines of every
# settlement made before this migration get each person's unit and
# active flag as they are when it runs, and units_recorded_on is that
# day, in the community's zone. A line's lived_here is then about that
# day, years after the settlement, so such a settlement does not split
# out who had moved out: its page counts everyone in the unit they live
# in, or last lived in, and says so (Reconciliation#records_who_moved_out?).
#
# Dated 20261010125950, before the day it was written (2026-10-14), on
# purpose. The data fixes from 20261010130000 to 20261013120100 work old
# settlements out again with Settlement#correct!, which writes these
# columns now. In production every one of those is still to run, and
# migrations run in the order of their dates, so these columns must come
# first. A database that ran the fixes already (development, a copy of
# production) runs this one after them and ends the same: the lines the
# fixes wrote get the same units as the rest.
class SaveEachPersonsUnitOnASettlementLine < ActiveRecord::Migration[8.1]
  # safety_assured: strong_migrations cannot read the execute blocks, and
  # it asks for a concurrent index, which cannot run in the transaction
  # the backfill needs for its SET LOCAL. Both tables are small (about
  # 600 lines and 10 settlements in production), on one dyno.
  def up
    safety_assured { unsafe_up }
  end

  # The saved units of the settlements made after this migration are not
  # anywhere else, so they are refused, the way 20261010125951 refuses to
  # drop a correction.
  def down
    saved = select_value('SELECT count(*) FROM reconciliations WHERE units_recorded_on <= date').to_i
    if saved.positive?
      raise "#{saved} settlement(s) saved each person's unit when they were made. Dropping the columns " \
            'would lose that, and the units cannot be read back from anywhere else.'
    end

    safety_assured do
      remove_column :reconciliations, :units_recorded_on
      remove_column :reconciliation_balances, :lived_here
      remove_reference :reconciliation_balances, :unit, foreign_key: true, index: true
    end
  end

  private

  def unsafe_up
    add_reference :reconciliation_balances, :unit, foreign_key: true, index: true
    add_column :reconciliation_balances, :lived_here, :boolean
    add_column :reconciliations, :units_recorded_on, :date

    # The lines are settled, so their guard refuses an update without the
    # repair bypass (docs/runbooks/settled-data-repair.md). SET LOCAL ends
    # with this migration's transaction.
    execute "SET LOCAL comeals.allow_settled_writes = 'on'"
    execute <<~SQL.squish
      UPDATE reconciliation_balances
      SET unit_id = residents.unit_id, lived_here = residents.active
      FROM residents
      WHERE residents.id = reconciliation_balances.resident_id
    SQL
    execute "SET LOCAL comeals.allow_settled_writes = ''"
    # The update queued a deferred sum-zero check (reconciliation_balances_sum_zero)
    # for each line, and Postgres refuses to ALTER a table with checks still
    # queued. Run them now: the amounts did not change, so they pass.
    execute 'SET CONSTRAINTS ALL IMMEDIATE'
    execute <<~SQL.squish
      UPDATE reconciliations
      SET units_recorded_on = (now() AT TIME ZONE communities.timezone)::date
      FROM communities
      WHERE communities.id = reconciliations.community_id
    SQL

    change_column_null :reconciliation_balances, :unit_id, false
    change_column_null :reconciliation_balances, :lived_here, false
    change_column_null :reconciliations, :units_recorded_on, false
  end
end
