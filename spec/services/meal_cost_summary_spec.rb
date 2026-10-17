# frozen_string_literal: true

require 'rails_helper'

# The display face of the money arithmetic. Open meals compute through
# MealLedger; settled meals read their stored meal_charges. These specs
# carry the display-path cases that used to live on Meal's deleted
# total_cost / effective_total_cost / unit_cost / subsidized? methods.
RSpec.describe MealCostSummary do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }

  def capped_setup(cap)
    capped_community = create(:community, cap: BigDecimal(cap))
    [capped_community, create(:unit, community: capped_community)]
  end

  describe 'an open meal (through MealLedger)' do
    it 'sums bill amounts, excluding no_cost bills' do
      meal = create(:meal, community: community)
      resident_a = create(:resident, community: community, unit: unit, multiplier: 2)
      resident_b = create(:resident, community: community, unit: unit, multiplier: 2)
      create(:meal_resident, meal: meal, resident: resident_a, community: community)
      create(:bill, meal: meal, resident: resident_a, community: community, amount: BigDecimal('30'))
      no_cost_bill_with_an_amount(meal: meal, resident: resident_b, amount: '20')
      meal.reload

      summary = described_class.for(meal)
      expect(summary.total_cost).to eq(BigDecimal('30'))
      expect(summary.total_cost).to be_a(BigDecimal)
    end

    it 'reports zeros for a meal with no bills' do
      meal = create(:meal, community: community)
      resident = create(:resident, community: community, unit: unit, multiplier: 2)
      create(:meal_resident, meal: meal, resident: resident, community: community)
      meal.reload

      summary = described_class.for(meal)
      expect(summary.total_cost).to eq(BigDecimal('0'))
      expect(summary.unit_cost).to eq(BigDecimal('0'))
    end

    it 'divides the effective cost by the multiplier for unit cost' do
      meal = create(:meal, community: community)
      resident_a = create(:resident, community: community, unit: unit, multiplier: 2)
      resident_b = create(:resident, community: community, unit: unit, multiplier: 1)
      create(:meal_resident, meal: meal, resident: resident_a, community: community)
      create(:meal_resident, meal: meal, resident: resident_b, community: community)
      cook = create(:resident, community: community, unit: unit, multiplier: 2)
      create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('30'))
      meal.reload

      # multiplier = 3, effective cost = 30, unit cost = 10
      summary = described_class.for(meal)
      expect(summary.unit_cost).to eq(BigDecimal('10'))
      expect(summary.unit_cost).to be_a(BigDecimal)
    end

    # Nobody with a price ate, so nobody can be charged and the cook is
    # credited nothing. "Subsidized" means the cooks were credited less
    # than they spent, for any reason, so this meal is subsidized (#94).
    it 'reports zero unit cost when the multiplier is zero, and subsidized (the cook absorbs the cost)' do
      meal = create(:meal, community: community)
      resident = create(:resident, community: community, unit: unit, multiplier: 2)
      create(:bill, meal: meal, resident: resident, community: community, amount: BigDecimal('50'))

      summary = described_class.for(meal)
      expect(summary.unit_cost).to eq(BigDecimal('0'))
      expect(summary.effective_cost).to eq(BigDecimal('0'))
      expect(summary.subsidized).to be true
    end

    # MODELS.md: total_cost is what the cooks spent. With no multiplier to
    # share the cost, it is still what they spent, not $0 (#94).
    it 'reports what the cooks spent as the total cost when the multiplier is zero' do
      meal = create(:meal, community: community)
      cook = create(:resident, community: community, unit: unit, multiplier: 2)
      create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('50'))

      expect(described_class.for(meal).total_cost).to eq(BigDecimal('50'))
    end

    it 'shows what the cook spent, and subsidized, on an open meal only a free eater ate' do
      meal = create(:meal, community: community)
      cook = create(:resident, community: community, unit: unit, multiplier: 2)
      baby = create(:resident, community: community, unit: unit, multiplier: 0)
      create(:meal_resident, meal: meal, resident: baby, community: community)
      create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('25'))

      summary = described_class.for(meal.reload)
      expect(summary.total_cost).to eq(BigDecimal('25'))
      expect(summary.effective_cost).to eq(BigDecimal('0'))
      expect(summary.unit_cost).to eq(BigDecimal('0'))
      expect(summary.subsidized).to be true
    end

    # The cook spent nothing, so the cook was not credited less than they
    # spent.
    it 'is not subsidized when only a free eater ate and the cook slot holds no money' do
      meal = create(:meal, community: community)
      cook = create(:resident, community: community, unit: unit, multiplier: 2)
      baby = create(:resident, community: community, unit: unit, multiplier: 0)
      create(:meal_resident, meal: meal, resident: baby, community: community)
      create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('0'))

      summary = described_class.for(meal.reload)
      expect(summary.total_cost).to eq(BigDecimal('0'))
      expect(summary.subsidized).to be false
    end

    it 'keeps the effective cost at the total when capped but under the cap' do
      capped_community, capped_unit = capped_setup('25')
      meal = create(:meal, community: capped_community)
      resident = create(:resident, community: capped_community, unit: capped_unit, multiplier: 2)
      create(:meal_resident, meal: meal, resident: resident, community: capped_community)
      create(:bill, meal: meal, resident: resident, community: capped_community, amount: BigDecimal('10'))
      meal.reload

      # cap allows 25 * 2 = 50; total 10 is under it
      summary = described_class.for(meal)
      expect(summary.effective_cost).to eq(BigDecimal('10'))
      expect(summary.subsidized).to be false
    end

    it 'caps the effective cost and reports subsidized when the cooks spent more' do
      capped_community, capped_unit = capped_setup('2.50')
      meal = create(:meal, community: capped_community)
      resident_a = create(:resident, community: capped_community, unit: capped_unit, multiplier: 2)
      resident_b = create(:resident, community: capped_community, unit: capped_unit, multiplier: 2)
      create(:meal_resident, meal: meal, resident: resident_a, community: capped_community)
      create(:bill, meal: meal, resident: resident_a, community: capped_community, amount: BigDecimal('4'))
      create(:bill, meal: meal, resident: resident_b, community: capped_community, amount: BigDecimal('6'))
      meal.reload

      # cap allows 2.50 * 2 = 5.00; the cooks spent 10
      summary = described_class.for(meal)
      expect(summary.total_cost).to eq(BigDecimal('10'))
      expect(summary.effective_cost).to eq(BigDecimal('5'))
      expect(summary.unit_cost).to eq(BigDecimal('2.5'))
      expect(summary.subsidized).to be true
    end

    it 'is not subsidized when uncapped, whatever the cooks spent' do
      meal = create(:meal, community: community)
      resident = create(:resident, community: community, unit: unit, multiplier: 2)
      create(:meal_resident, meal: meal, resident: resident, community: community)
      create(:bill, meal: meal, resident: resident, community: community, amount: BigDecimal('100'))
      meal.reload

      summary = described_class.for(meal)
      expect(summary.effective_cost).to eq(BigDecimal('100'))
      expect(summary.subsidized).to be false
    end
  end

  # The meal's own page shows what a corrected settled meal costs after
  # the correction (ADR 0011 rule 6); the settlement's page keeps what it
  # settled.
  describe '.now' do
    let(:cook) { create(:resident, community: community, unit: unit) }
    let(:meal) do
      create(:meal, community: community).tap do |meal|
        create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('30'))
        create(:meal_resident, meal: meal, resident: create(:resident, community: community, unit: unit),
                               community: community)
        settle!
      end.reload
    end

    it 'reads a corrected settled meal from its rows, where `for` keeps what it was settled at' do
      MealCorrecting.save!(meal, by: create(:admin_user, community: community), reason: 'Typed $30 for $20') do |edits|
        edits.cost(cook, amount: BigDecimal('20'), no_cost: false)
      end
      meal.reload

      expect(described_class.now(meal).total_cost).to eq(BigDecimal('20'))
      expect(described_class.for(meal).total_cost).to eq(BigDecimal('30'))
    end

    it 'reads a settled meal with no correction the same as `for`, from its stored lines' do
      expect(described_class.now(meal).serialize).to eq(described_class.for(meal).serialize)
      expect(described_class.now(meal).total_cost).to eq(BigDecimal('30'))
    end

    # A meal is corrected only once it is settled, so `now` does not ask
    # about corrections for an open meal: with its rows loaded, it runs no
    # query at all.
    it 'reads no correction for an open meal' do
      open_meal = create(:meal, community: community)
      create(:bill, meal: open_meal, resident: cook, community: community, amount: BigDecimal('12'))
      create(:meal_resident, meal: open_meal, resident: cook, community: community)
      loaded = Meal.preload(:bills, :meal_residents, :guests).find(open_meal.id)

      expect(count_queries { expect(described_class.now(loaded).total_cost).to eq(BigDecimal('12')) }).to eq(0)
    end
  end

  describe 'a settled meal (from stored charges)' do
    # A settled meal nobody ate gets no charges; the summary then shows
    # what the cooks spent, from the bills, and a no-cost bill spends
    # nothing whatever amount was left on it. The cook was credited
    # nothing for the $10, so the meal is subsidized, the same as an open
    # meal nobody ate (#94).
    it 'sums only the bills with money on a settled meal that got no charges, and calls it subsidized' do
      meal = create(:meal, community: community)
      cook = create(:resident, community: community, unit: unit, multiplier: 2)
      other = create(:resident, community: community, unit: unit, multiplier: 2)
      create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('10'))
      no_cost_bill_with_an_amount(meal: meal, resident: other, amount: '12')
      meal.update!(reconciliation: create(:reconciliation, community: community))

      summary = described_class.for(meal.reload)
      expect(summary.total_cost).to eq(BigDecimal('10'))
      expect(summary.effective_cost).to eq(BigDecimal('0'))
      expect(summary.unit_cost).to eq(BigDecimal('0'))
      expect(summary.subsidized).to be true
    end

    # A settled meal's rows are frozen, so a fresh computation from them
    # gives the stored numbers too, unless a row changed. These examples
    # change one behind the guards, the way the repair bypass can, so a
    # summary computed from the rows shows different numbers and only
    # reading the stored charges shows the settled ones.
    def behind_the_guards
      ActiveRecord::Base.transaction do
        ActiveRecord::Base.connection.execute("SET LOCAL comeals.allow_settled_writes = 'on'")
        yield
      end
    end

    it 'reads the stored charges, not the live bills' do
      meal = create(:meal, community: community)
      cook = create(:resident, community: community, unit: unit, multiplier: 2)
      eater = create(:resident, community: community, unit: unit, multiplier: 2)
      create(:meal_resident, meal: meal, resident: eater, community: community)
      create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('16'))
      settle!

      # From the bills this would be 99 spent, 99 charged, 49.50 a unit.
      behind_the_guards { Bill.where(meal_id: meal.id).update_all(amount: BigDecimal('99')) }

      summary = described_class.for(meal.reload)
      expect(summary.total_cost).to eq(BigDecimal('16'))
      expect(summary.effective_cost).to eq(BigDecimal('16'))
      expect(summary.unit_cost).to eq(BigDecimal('8'))
      expect(summary.subsidized).to be false
    end

    it 'reads the stored lines with one query' do
      meal = create(:meal, community: community)
      cook = create(:resident, community: community, unit: unit, multiplier: 2)
      eater = create(:resident, community: community, unit: unit, multiplier: 2)
      create(:meal_resident, meal: meal, resident: eater, community: community)
      create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('16'))
      settle!
      meal.reload

      expect(count_queries { expect(described_class.for(meal).total_cost).to eq(BigDecimal('16')) }).to eq(1)
    end

    it "reads the stored subsidy, not the meal's cap" do
      capped_community, capped_unit = capped_setup('2.50')
      meal = create(:meal, community: capped_community)
      cook = create(:resident, community: capped_community, unit: capped_unit, multiplier: 2)
      eater = create(:resident, community: capped_community, unit: capped_unit, multiplier: 2)
      create(:meal_resident, meal: meal, resident: eater, community: capped_community)
      create(:bill, meal: meal, resident: cook, community: capped_community, amount: BigDecimal('10'))
      settle!

      # From the rows, a $100 cap allows $200, so the $10 spent would be
      # charged in full and the meal would not be subsidized.
      behind_the_guards { Meal.where(id: meal.id).update_all(cap: BigDecimal('100')) }

      summary = described_class.for(meal.reload)
      expect(summary.total_cost).to eq(BigDecimal('10'))
      expect(summary.effective_cost).to eq(BigDecimal('5'))
      expect(summary.unit_cost).to eq(BigDecimal('2.5'))
      expect(summary.subsidized).to be true
    end

    # The ledger reads the meal's own cap, which the meal copies from the
    # community when it is made. So a later change to the community cap
    # does not reach a meal that already exists.
    it 'shows the same numbers after the community cap changes, because the meal keeps its own cap' do
      capped_community, capped_unit = capped_setup('2.50')
      meal = create(:meal, community: capped_community)
      cook = create(:resident, community: capped_community, unit: capped_unit, multiplier: 2)
      eater = create(:resident, community: capped_community, unit: capped_unit, multiplier: 2)
      create(:meal_resident, meal: meal, resident: eater, community: capped_community)
      create(:bill, meal: meal, resident: cook, community: capped_community, amount: BigDecimal('10'))
      settle!

      settled = described_class.for(meal.reload)
      expect(settled.effective_cost).to eq(BigDecimal('5'))
      expect(settled.subsidized).to be true

      capped_community.update!(cap: BigDecimal('100'))
      expect(meal.reload.cap).to eq(BigDecimal('2.5'))
      expect(described_class.for(meal).effective_cost).to eq(BigDecimal('5'))
      expect(described_class.for(meal).subsidized).to be true
    end

    # A meal with $25 on a receipt that only a free eater ate. A
    # settlement holds such a meal back now (Meal.settleable_by), but one
    # settled before 2026-10-09 got the lines a settlement wrote then: a
    # zero credit for the cook and a zero debit for the eater. This builds
    # that meal: claimed by a settlement, with those two lines.
    def free_eater_meal_settled_before_the_hold_back
      reconciliation = create(:reconciliation, community: community)
      meal = create(:meal, community: community)
      cook = create(:resident, community: community, unit: unit, multiplier: 2)
      baby = create(:resident, community: community, unit: unit, multiplier: 0)
      create(:meal_resident, meal: meal, resident: baby, community: community)
      create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('25'))
      open = described_class.for(meal.reload)

      meal.update_columns(reconciliation_id: reconciliation.id)
      as_settlement_of(reconciliation) do
        MealCharge.create!(meal: meal, resident: cook, kind: 'credit', amount: BigDecimal('0'),
                           unit_cost: BigDecimal('0'), bill_amount: BigDecimal('25'))
        MealCharge.create!(meal: meal, resident: baby, kind: 'debit', amount: BigDecimal('0'),
                           unit_cost: BigDecimal('0'), multiplier: 0)
      end
      [meal.reload, open]
    end

    # Nobody is charged, but the meal still has lines. The summary reads
    # them, so it shows zeros and what the cook spent, not nothing, and
    # calls the meal subsidized: the cook got back $0 of $25 (#94).
    it 'shows zeros, not nothing, for a settled meal only a free eater ate' do
      meal, = free_eater_meal_settled_before_the_hold_back

      expect(meal).to be_reconciled
      summary = described_class.for(meal)
      expect(summary).not_to be_nil
      expect(summary.total_cost).to eq(BigDecimal('25'))
      expect(summary.effective_cost).to eq(BigDecimal('0'))
      expect(summary.unit_cost).to eq(BigDecimal('0'))
      expect(summary.subsidized).to be true
    end

    # Settling changed no source row, so the screen must not change: the
    # open meal computed through MealLedger and the settled meal read from
    # its lines show the same numbers (#94).
    it 'shows the same numbers before and after settling a meal only a free eater ate' do
      meal, open = free_eater_meal_settled_before_the_hold_back

      expect(meal).to be_reconciled
      expect(described_class.for(meal).serialize).to eq(open.serialize)
    end

    # A no-cost bill writes no credit line, so the lines are the eaters'
    # zero debits alone, and the sums over the credits add up nothing.
    it 'shows zeros for a settled no-cost meal people ate, which has debit lines and no credit' do
      meal = create(:meal, community: community)
      cook = create(:resident, community: community, unit: unit, multiplier: 2)
      eater = create(:resident, community: community, unit: unit, multiplier: 2)
      create(:meal_resident, meal: meal, resident: eater, community: community)
      create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('0'), no_cost: true)
      settle!

      expect(meal.reload.meal_charges.map { |charge| [charge.kind, charge.resident_id, charge.amount] })
        .to eq([['debit', eater.id, BigDecimal('0')]])
      summary = described_class.for(meal)
      expect([summary.total_cost, summary.effective_cost, summary.unit_cost]).to all(be_a(BigDecimal))
      expect([summary.total_cost, summary.effective_cost, summary.unit_cost]).to all(be_zero)
      expect(summary.subsidized).to be false
    end

    it 'shows zeros for a settled meal nobody ate whose only bill is no-cost' do
      meal = create(:meal, community: community)
      cook = create(:resident, community: community, unit: unit, multiplier: 2)
      create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('0'), no_cost: true)
      settle!

      expect(meal.reload.reconciliation_id).not_to be_nil
      expect(meal.meal_charges).to be_empty
      summary = described_class.for(meal)
      expect(summary.total_cost).to be_a(BigDecimal)
      expect(summary.total_cost).to be_zero
      # The cook spent nothing, so nothing was held back from them.
      expect(summary.subsidized).to be false
    end

    it 'shows the receipts and zero charges for a meal nobody attended' do
      meal = create(:meal, community: community)
      cook = create(:resident, community: community, unit: unit, multiplier: 2)
      create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('40'))
      # Settled before 2026-09-10, when a receipt nobody ate was still swept
      # (138 such meals exist in production). A settlement holds it back
      # now, so the row is set the way those old ones are.
      reconciliation = create(:reconciliation, community: community)
      meal.update_columns(reconciliation_id: reconciliation.id)

      # Swept, but no lines: nobody was charged, the cook absorbed the
      # receipts.
      summary = described_class.for(meal.reload)
      expect(meal.meal_charges).to be_empty
      expect(summary.total_cost).to eq(BigDecimal('40'))
      expect(summary.effective_cost).to eq(BigDecimal('0'))
      expect(summary.unit_cost).to eq(BigDecimal('0'))
    end

    it 'returns nil for a settlement from before line items existed when only a guest ate' do
      reconciliation = create(:reconciliation, community: community)
      meal = create(:meal, community: community)
      cook = create(:resident, community: community, unit: unit, multiplier: 2)
      create(:guest, meal: meal, resident: cook)
      create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('16'))
      meal.update_columns(reconciliation_id: reconciliation.id)

      expect(described_class.for(meal.reload)).to be_nil
    end

    it 'returns nil for a settlement from before line items existed' do
      # The reconciliation first — the factory sweeps every eligible meal
      # on create, and this meal must end up reconciled WITHOUT charges.
      reconciliation = create(:reconciliation, community: community)

      meal = create(:meal, community: community)
      cook = create(:resident, community: community, unit: unit, multiplier: 2)
      eater = create(:resident, community: community, unit: unit, multiplier: 2)
      create(:meal_resident, meal: meal, resident: eater, community: community)
      create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('16'))

      # A pre-2026-08-02 settlement: reconciled, attendance, no charge rows.
      meal.update_columns(reconciliation_id: reconciliation.id)

      expect(described_class.for(meal.reload)).to be_nil
    end
  end

  # A settled dinner nobody ate has no stored lines, so its numbers come
  # from its receipts and its sign-ups. A correction (ADR 0011 rule 6)
  # changes those rows later, and the record of each edit keeps the value
  # before it. `for` is what the dinner was settled at (the settlement's
  # page), so it reads the rows as they were when it settled (#177).
  describe 'a settled dinner nobody ate, corrected later' do
    let(:admin) { create(:admin_user, community: community) }
    let(:cook) { create(:resident, community: community, unit: unit) }
    let(:eater) { create(:resident, community: community, unit: unit) }
    let(:latest) { Reconciliation.latest_cutoff(community.today) }
    let(:dinner) { create(:meal, community: community, date: latest - 5) }
    # A settlement made before the dinner, so the factory's sweep does not
    # take the dinner, and the dinner is then marked settled by it, the
    # way an old one is.
    let!(:old_settlement) { create(:reconciliation, community: community) }

    # A settlement must charge someone, so a second dinner with an eater
    # goes in the same one.
    def settle_with_another_dinner
      other = create(:meal, community: community, date: latest - 6)
      create(:bill, meal: other, resident: cook, community: community, amount: BigDecimal('8'))
      create(:meal_resident, meal: other, resident: eater, community: community)
      settle!(cutoff: latest - 5)
    end

    def correct(reason, &)
      MealCorrecting.save!(dinner.reload, by: admin, reason: reason, &)
      dinner.reload
    end

    it 'shows the cost it was settled at, not a cost a correction added' do
      create(:bill, meal: dinner, resident: cook, community: community, amount: BigDecimal('0'))
      settle_with_another_dinner
      correct('The cook paid $20 after all') { |edits| edits.cost(cook, amount: BigDecimal('20'), no_cost: false) }

      expect(described_class.for(dinner)).to have_attributes(total_cost: 0, effective_cost: 0, unit_cost: 0,
                                                             subsidized: false)
      expect(described_class.now(dinner).total_cost).to eq(BigDecimal('20'))
    end

    # Each cook's cost when it settled is the "from" of the first edit
    # that names them. A later edit's "from" is a cost the first one set.
    it 'shows the receipts of an old settlement after two corrections change a cook and then remove them' do
      other_cook = create(:resident, community: community, unit: unit)
      create(:bill, meal: dinner, resident: cook, community: community, amount: BigDecimal('10'))
      create(:bill, meal: dinner, resident: other_cook, community: community, amount: BigDecimal('9'))
      # Swept before 2026-09-10, when a receipt nobody ate was still swept.
      dinner.update_columns(reconciliation_id: old_settlement.id)
      correct('Typed $9 for $5') { |edits| edits.cost(other_cook, amount: BigDecimal('5'), no_cost: false) }
      correct('The second cook did not cook') { |edits| edits.remove_cook(other_cook) }

      expect(described_class.for(dinner)).to have_attributes(total_cost: BigDecimal('19'), subsidized: true)
      expect(described_class.now(dinner).total_cost).to eq(BigDecimal('10'))
    end

    it 'leaves out a cook a correction added, and keeps what another cook was settled at' do
      other_cook = create(:resident, community: community, unit: unit)
      create(:bill, meal: dinner, resident: cook, community: community, amount: BigDecimal('40'))
      dinner.update_columns(reconciliation_id: old_settlement.id)
      correct('Typed $40 for $20, and a second cook spent $15') do |edits|
        edits.cost(cook, amount: BigDecimal('20'), no_cost: false)
        edits.cost(other_cook, amount: BigDecimal('15'), no_cost: false)
      end

      expect(described_class.for(dinner).total_cost).to eq(BigDecimal('40'))
      expect(described_class.now(dinner).total_cost).to eq(BigDecimal('35'))
    end

    # An eater edit names a resident too. It says nothing about their
    # cost, even when they also cooked.
    it 'reads a cook\'s settled cost past an edit that adds them as an eater' do
      create(:bill, meal: dinner, resident: cook, community: community, amount: BigDecimal('40'))
      dinner.update_columns(reconciliation_id: old_settlement.id)
      correct('The cook ate too, and typed $40 for $25') do |edits|
        edits.add_eater(cook)
        edits.cost(cook, amount: BigDecimal('25'), no_cost: false)
      end

      expect(described_class.for(dinner).total_cost).to eq(BigDecimal('40'))
    end

    # Before 2026-10-10 a bill could be No cost and still hold an amount
    # (no_cost_bill_with_an_amount). It spent nothing when it settled.
    it 'leaves out a cost that was No cost when it settled, whatever amount it held' do
      create(:bill, meal: dinner, resident: cook, community: community, amount: BigDecimal('10'))
      other_cook = create(:resident, community: community, unit: unit)
      no_cost_bill_with_an_amount(meal: dinner, resident: other_cook, amount: '12')
      dinner.update_columns(reconciliation_id: old_settlement.id)
      correct('The second cook did spend $12') do |edits|
        edits.cost(other_cook, amount: BigDecimal('12'), no_cost: false)
      end

      expect(described_class.for(dinner).total_cost).to eq(BigDecimal('10'))
      expect(described_class.now(dinner).total_cost).to eq(BigDecimal('22'))
    end

    it 'shows the receipts of an old settlement, swept with money on them, after a correction changes one' do
      create(:bill, meal: dinner, resident: cook, community: community, amount: BigDecimal('40'))
      # Swept before 2026-09-10, when a receipt nobody ate was still swept.
      dinner.update_columns(reconciliation_id: old_settlement.id)
      correct('Typed $40 for $25') { |edits| edits.cost(cook, amount: BigDecimal('25'), no_cost: false) }

      expect(described_class.for(dinner)).to have_attributes(total_cost: BigDecimal('40'), subsidized: true)
    end

    it 'still shows that nobody was charged after a correction adds an eater' do
      create(:bill, meal: dinner, resident: cook, community: community, amount: BigDecimal('0'))
      settle_with_another_dinner
      correct('The eater forgot to sign up') { |edits| edits.add_eater(eater) }

      expect(described_class.for(dinner)).to have_attributes(total_cost: 0, effective_cost: 0, unit_cost: 0)
    end

    it 'still shows that nobody was charged after a correction adds a guest and removes it again' do
      create(:bill, meal: dinner, resident: cook, community: community, amount: BigDecimal('0'))
      settle_with_another_dinner
      correct('A guest came') { |edits| edits.add_guest(eater, multiplier: 2) }
      correct('Two guests came, not one') { |edits| edits.add_guest(eater, multiplier: 2) }
      correct('One guest did not come') { |edits| edits.remove_guest(dinner.guests.first) }

      expect(described_class.for(dinner)).to have_attributes(total_cost: 0, effective_cost: 0)
    end

    it 'shows nothing for a dinner people ate on a settlement from before line items, after a correction ' \
       'removes them' do
      create(:bill, meal: dinner, resident: cook, community: community, amount: BigDecimal('16'))
      create(:meal_resident, meal: dinner, resident: eater, community: community)
      # Settled, and then its line items taken off with the repair bypass:
      # the state of a settlement made before line items existed.
      settled = settle!(cutoff: latest - 5)
      with_repair_bypass { MealCharge.for_reconciliation(settled).delete_all }
      correct('The eater was away') { |edits| edits.remove_eater(eater) }

      expect(described_class.for(dinner)).to be_nil
    end

    # One eater when it settled and two now: a correction adds one, and
    # takes one away from the count, never two.
    it 'shows nothing for a dinner one person ate on a settlement from before line items, after a correction ' \
       'adds a second' do
      create(:bill, meal: dinner, resident: cook, community: community, amount: BigDecimal('16'))
      create(:meal_resident, meal: dinner, resident: eater, community: community)
      settled = settle!(cutoff: latest - 5)
      with_repair_bypass { MealCharge.for_reconciliation(settled).delete_all }
      correct('A second eater forgot to sign up') { |edits| edits.add_eater(cook) }

      expect(described_class.for(dinner)).to be_nil
    end
  end
end
