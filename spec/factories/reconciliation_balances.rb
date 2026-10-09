# frozen_string_literal: true

# == Schema Information
#
# Table name: reconciliation_balances
#
#  id                :bigint           not null, primary key
#  amount            :decimal(16, 8)   default(0.0), not null
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#  reconciliation_id :bigint           not null
#  resident_id       :bigint           not null
#
# Indexes
#
#  index_recon_balances_on_recon_id_and_resident_id  (reconciliation_id,resident_id) UNIQUE
#  index_reconciliation_balances_on_resident_id      (resident_id)
#
# Foreign Keys
#
#  fk_rails_...  (reconciliation_id => reconciliations.id)
#  fk_rails_...  (resident_id => residents.id)
#
FactoryBot.define do
  factory :reconciliation_balance do
    reconciliation
    resident
    amount { BigDecimal('0') }

    # The database refuses a balance that its reconciliation's settlement
    # is not writing (20261009120000), so the factory writes it as that
    # settlement would.
    to_create do |balance|
      SettledWrites.as_settlement_of(balance.reconciliation) { balance.save! }
    end
  end
end
