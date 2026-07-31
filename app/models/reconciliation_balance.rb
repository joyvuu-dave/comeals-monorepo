# frozen_string_literal: true

# == Schema Information
#
# Table name: reconciliation_balances
#
#  id                :bigint           not null, primary key
#  amount            :decimal(12, 8)   default(0.0), not null
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#  reconciliation_id :bigint           not null
#  resident_id       :bigint           not null
#
# Indexes
#
#  index_recon_balances_on_recon_id_and_resident_id    (reconciliation_id,resident_id) UNIQUE
#  index_reconciliation_balances_on_reconciliation_id  (reconciliation_id)
#  index_reconciliation_balances_on_resident_id        (resident_id)
#
# Foreign Keys
#
#  fk_rails_...  (reconciliation_id => reconciliations.id)
#  fk_rails_...  (resident_id => residents.id)
#
class ReconciliationBalance < ApplicationRecord
  belongs_to :reconciliation
  belongs_to :resident

  validates :amount, numericality: true
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
  # reject_destroy is prepended so it aborts before any cascade can run, for
  # the reason spelled out on Meal and Reconciliation (issue #26).
  before_update :reject_update
  before_destroy :reject_destroy, prepend: true

  def reject_update
    errors.add(:base, 'Settled balances are what residents have already been billed and cannot be ' \
                      'modified. Corrections settle as new entries in the next reconciliation.')
    throw(:abort)
  end

  def reject_destroy
    errors.add(:base, 'Settled balances are what residents have already been billed and cannot be destroyed.')
    throw(:abort)
  end
end
