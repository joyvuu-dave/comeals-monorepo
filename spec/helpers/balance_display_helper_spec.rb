# frozen_string_literal: true

require 'rails_helper'

# The direction words are the one thing this app must never get backwards:
# telling a resident they owe money when they are owed it. So these specs pin
# the words two ways. The unit tests pin what each sign renders as. The
# ledger test derives the expected words from MealLedger's own arithmetic —
# it does not trust the documented sign convention, it re-proves it.
RSpec.describe BalanceDisplayHelper do
  describe '#balance_tag' do
    it 'says "is owed" for a positive amount' do
      html = helper.balance_tag(BigDecimal('12.50'))
      expect(html).to eq('<span class="balance-is-owed">is owed $12.50</span>')
    end

    it 'says "owes" for a negative amount, without a minus sign' do
      html = helper.balance_tag(BigDecimal('-12.50'))
      expect(html).to eq('<span class="balance-owes">owes $12.50</span>')
      expect(html).not_to include('-$')
    end

    it 'shows a plain $0.00 for zero — zero has no direction' do
      expect(helper.balance_tag(BigDecimal('0'))).to eq('<span class="balance-zero">$0.00</span>')
    end

    it 'decides the direction from the rounded cents, so a sub-cent debt is not "owes $0.00"' do
      expect(helper.balance_tag(BigDecimal('-0.004'))).to eq('<span class="balance-zero">$0.00</span>')
      expect(helper.balance_tag(BigDecimal('0.004'))).to eq('<span class="balance-zero">$0.00</span>')
    end

    it 'still shows a debt that rounds to a whole cent' do
      expect(helper.balance_tag(BigDecimal('-0.006'))).to eq('<span class="balance-owes">owes $0.01</span>')
      expect(helper.balance_tag(BigDecimal('0.006'))).to eq('<span class="balance-is-owed">is owed $0.01</span>')
    end

    it 'rounds a full-precision running balance to cents for display' do
      # 50 / 7, the repeating decimal from the money model in CLAUDE.md.
      expect(helper.balance_tag(BigDecimal('-7.14285714'))).to eq('<span class="balance-owes">owes $7.14</span>')
    end
  end

  describe '#balance_tag against MealLedger itself' do
    let(:community) { create(:community) }
    let(:unit) { create(:unit, community: community) }
    let(:cook) { create(:resident, community: community, unit: unit, multiplier: 2, name: 'Cook') }
    let(:eater) { create(:resident, community: community, unit: unit, multiplier: 2, name: 'Eater') }

    it 'shows the cook as owed and the eater as owing, derived from the arithmetic, not the docs' do
      # The cook spends $16 and does not eat; the eater eats alone. Whatever
      # sign MealLedger gives those balances, the cook must read "is owed"
      # and the eater must read "owes". If anyone ever flips the sign
      # convention in MealLedger without flipping the helper, this fails.
      meal = create(:meal, community: community)
      create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('16'))
      create(:meal_resident, meal: meal, resident: eater, community: community, multiplier: 2)

      balances = MealLedger.new([meal]).balances([cook.id, eater.id])

      expect(helper.balance_tag(balances[cook.id])).to include('is owed $16.00')
      expect(helper.balance_tag(balances[eater.id])).to include('owes $16.00')
    end
  end

  describe '#charge_amount_tag' do
    let(:community) { create(:community) }
    let(:unit) { create(:unit, community: community) }
    let(:cook) { create(:resident, community: community, unit: unit, multiplier: 2, name: 'Cook') }
    let(:eater) { create(:resident, community: community, unit: unit, multiplier: 2, name: 'Eater') }

    # Settle a real meal so the charges come from MealLedger, not from
    # hand-built rows that could encode a wrong sign. $16 across 4 units of
    # multiplier: the cook (who also eats) is credited $16 and charged $8,
    # the eater is charged $8.
    def settle_meal
      meal = create(:meal, community: community)
      create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('16'))
      create(:meal_resident, meal: meal, resident: cook, community: community, multiplier: 2)
      create(:meal_resident, meal: meal, resident: eater, community: community, multiplier: 2)
      Reconciliation.create!(community: community, end_date: Date.yesterday)
    end

    it 'says "credited" for a cook credit and "charged" for a debit, with no minus sign' do
      settle_meal

      credit = MealCharge.credits.find_by(resident: cook)
      debit = MealCharge.debits.find_by(resident: eater)

      expect(helper.charge_amount_tag(credit)).to eq('<span class="balance-is-owed">credited $16.00</span>')
      expect(helper.charge_amount_tag(debit)).to eq('<span class="balance-owes">charged $8.00</span>')
    end

    it 'says "charged" for a guest debit too' do
      meal = create(:meal, community: community)
      create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('16'))
      create(:meal_resident, meal: meal, resident: eater, community: community, multiplier: 2)
      create(:guest, meal: meal, resident: eater, multiplier: 2)
      Reconciliation.create!(community: community, end_date: Date.yesterday)

      guest_debit = MealCharge.find_by(resident: eater, kind: 'guest_debit')

      expect(helper.charge_amount_tag(guest_debit)).to eq('<span class="balance-owes">charged $8.00</span>')
    end
  end

  describe '#settlement_totals_tag' do
    it 'splits the total into each direction and shows the difference is zero' do
      amounts = [BigDecimal('16'), BigDecimal('-8'), BigDecimal('-8')]

      html = helper.settlement_totals_tag(amounts, 'residents')

      expect(html).to include('Owed to residents: $16.00')
      expect(html).to include('Owed by residents: $16.00')
      expect(html).to include('Difference: $0.00 ✓')
    end

    it 'shows a non-zero difference in the error style instead of hiding it' do
      html = helper.settlement_totals_tag([BigDecimal('16'), BigDecimal('-8')], 'units')

      expect(html).to include('Difference: $8.00')
      expect(html).to include('balance-owes')
      expect(html).not_to include('✓')
    end

    it 'reports all zeros for an empty settlement' do
      html = helper.settlement_totals_tag([], 'units')

      expect(html).to include('Owed to units: $0.00')
      expect(html).to include('Owed by units: $0.00')
      expect(html).to include('Difference: $0.00 ✓')
    end
  end
end
