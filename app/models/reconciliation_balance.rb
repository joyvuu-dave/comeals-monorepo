# typed: strict
# frozen_string_literal: true

# == Schema Information
#
# Table name: reconciliation_balances
#
#  id                :bigint           not null, primary key
#  amount            :decimal(16, 8)   default(0.0), not null
#  lived_here        :boolean          not null
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#  reconciliation_id :bigint           not null
#  resident_id       :bigint           not null
#  unit_id           :bigint           not null
#
# Indexes
#
#  index_recon_balances_on_recon_id_and_resident_id  (reconciliation_id,resident_id) UNIQUE
#  index_reconciliation_balances_on_resident_id      (resident_id)
#  index_reconciliation_balances_on_unit_id          (unit_id)
#
# Foreign Keys
#
#  fk_rails_...  (reconciliation_id => reconciliations.id)
#  fk_rails_...  (resident_id => residents.id)
#  fk_rails_...  (unit_id => units.id)
#
# One resident's final settled amount for one reconciliation, rounded to
# cents by largest-remainder allocation.
#
# SIGN CONVENTION — `amount` is signed the way MealLedger signs everything
# (see its "Signs" section):
#
#   positive  =>  the community owes this resident money  ("is owed")
#   negative  =>  this resident owes the community money   ("owes")
#
# Never show this sign to a person. Screens render balances through
# BalanceDisplayHelper#balance_tag, which turns the sign into those words.
#
# The line also saves the person's unit and whether they lived here on the
# day the units were saved (ADR 0011 rule 7): `unit` is the unit they
# lived in, or last lived in, and `lived_here` is their active flag. That
# day is reconciliations.units_recorded_on: the day of the settlement, or
# for one made before migration 20261010125950, the day it ran. The unit
# totals on the settlement page come from these, so they never change
# later. A settlement whose units were saved on its own day counts the
# people who had moved out under "Moved out", not in a unit
# (Reconciliation#records_who_moved_out?).
class ReconciliationBalance < ApplicationRecord
  belongs_to :reconciliation
  belongs_to :resident
  belongs_to :unit

  validates :amount, numericality: true
  validates :lived_here, inclusion: { in: [true, false], message: TrueOrFalse::MESSAGE }
  validates :resident_id, uniqueness: { scope: :reconciliation_id }

  # A settled balance is what a resident has already been billed. It is
  # written once, inside the settlement transaction, and never again.
  #
  # These guards produce the readable error; the database triggers in
  # 20260731120000 are the backstop for writes that skip callbacks —
  # update_all, delete_all, a rake task, psql. Same split as the settled-meal
  # triggers, and the same reason: a validation only runs when the write goes
  # through the model.
  #
  # Adding a balance has no guard here, only in the database: the trigger in
  # 20261009120000 refuses an INSERT unless its reconciliation's settlement
  # is writing it, or the repair bypass is on. The settlement itself adds
  # balances through this model, so the model cannot refuse them.
  #
  include AppendOnly

  append_only update_message: 'Settled balances are what residents have already been billed and cannot be ' \
                              'modified. Corrections settle as new entries in the next reconciliation.',
              destroy_message: 'Settled balances are what residents have already been billed and cannot be destroyed.'
end
