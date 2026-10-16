# frozen_string_literal: true

require 'rails_helper'

# Settlement#correct! on a settlement one of whose dinners was already
# corrected (ADR 0011 rule 6).
#
# correct! works the settlement out again from its meals' rows as they are
# now. Its balances come from Reconciliation#settlement_balances, which
# takes every correction to the settlement's meals off again, so they
# would be what the settlement settled plus the new fix. But its line
# items come straight from the ledger's lines, and the ledger reads the
# corrected dinner's rows, correction included. So the corrected dinner's
# stored lines would hold the correction, the correction's own lines would
# be counted on top of them, and the nightly check's dinner and line item
# checks would fail for this settlement every night.
#
# Bug hunt 2026-10-16 (money) found that correct! went ahead. It now
# refuses such a settlement before it writes anything
# (Settlement::DinnerCorrected): the settlement keeps what it settled, and
# the corrections carry every change.
RSpec.describe Settlement, '#correct!' do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:latest) { Reconciliation.latest_cutoff(community.today) }
  let(:admin) { create(:admin_user, community: community, superuser: true) }
  let(:cook) { create(:resident, community: community, unit: unit, name: 'Cook') }
  let(:eater) { create(:resident, community: community, unit: unit, name: 'Eater') }

  # Two dinners settled together: $30 and $12. Then the $30 one is
  # corrected to $20 through rule 6, and a later settlement carries it.
  let!(:corrected) { dinner(latest - 6, '30') }
  let!(:repaired) { dinner(latest - 5, '12') }
  let!(:reconciliation) { settle!(cutoff: latest - 5) }

  def dinner(date, amount)
    create(:meal, community: community, date: date).tap do |meal|
      create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal(amount))
      create(:meal_resident, meal: meal, resident: eater, community: community)
    end
  end

  def findings
    LedgerVerification.call.details
  rescue LedgerVerification::MismatchError => e
    e.run.details
  end

  before do
    MealCorrecting.save!(corrected.reload, by: admin, reason: 'Typed $30 for $20') do |edits|
      edits.cost(cook, amount: BigDecimal('20'), no_cost: false)
    end
    dinner(latest, '8')
    settle!(cutoff: latest)
  end

  it 'refuses, writing nothing, when one of its dinners was corrected before' do
    expect(findings).to eq([])

    expect do
      described_class.new(reconciliation).correct!(reason: 'The $12 receipt was $15') do
        SettledWrites.with_repair_bypass { repaired.bills.sole.update_columns(amount: BigDecimal('15')) }
      end
    end.to raise_error(described_class::DinnerCorrected, /settlement #{reconciliation.id} has a correction/)

    # What the settlement settled: $30 and $12, and the fix did not run.
    expect(repaired.bills.sole.amount).to eq(BigDecimal('12'))
    expect(reconciliation.reconciliation_balances.pluck(:resident_id, :amount).to_h)
      .to eq(cook.id => BigDecimal('42'), eater.id => BigDecimal('-42'))
    expect(SettlementCorrection.count).to eq(0)
    expect(findings).to eq([])
  end
end
