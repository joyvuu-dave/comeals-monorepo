# frozen_string_literal: true

require 'rails_helper'

# Settlement#correct! on a settlement one of whose dinners was already
# corrected (ADR 0011 rule 6).
#
# correct! works the settlement out again from its meals' rows as they are
# now. Its balances come from Reconciliation#settlement_balances, which
# takes every correction to the settlement's meals off again, so they are
# what the settlement settled plus the new fix. But its line items come
# straight from the ledger's lines, and the ledger reads the corrected
# dinner's rows, correction included. So after correct! the corrected
# dinner's stored lines already hold the correction, and the correction's
# own lines are counted on top of them.
#
# The runbook (docs/runbooks/settled-data-repair.md) says to use correct!
# "the same way for the next repair of this kind" and that "ledger:verify
# then finds the settlement matching its rows". Until rule 10 removes
# correct!, both can be in use at once.
#
# Bug hunt 2026-10-16 (money). After correct!, the nightly check fails for
# this settlement every night: the dinner check (stored line plus
# correction is not what the rows add up to) and the line item check (the
# lines no longer add up to the balances).
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

  it 'leaves the settlement matching its rows when one of its dinners was corrected before' do
    expect(findings).to eq([])

    described_class.new(reconciliation).correct!(reason: 'The $12 receipt was $15') do
      SettledWrites.with_repair_bypass { repaired.bills.sole.update_columns(amount: BigDecimal('15')) }
    end

    # What the settlement settled ($42) plus the repair ($3). The $10
    # correction is carried by the next settlement, not this one.
    expect(reconciliation.reconciliation_balances.pluck(:resident_id, :amount).to_h)
      .to eq(cook.id => BigDecimal('45'), eater.id => BigDecimal('-45'))
    expect(findings).to eq([])
  end
end
