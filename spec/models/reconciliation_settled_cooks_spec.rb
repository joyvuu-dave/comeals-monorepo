# frozen_string_literal: true

require 'rails_helper'

# Who cooked a dinner in a settlement, as the settlement settled it
# (Reconciliation.settled_cooks). A correction changes a settled
# dinner's bills later (ADR 0011 rule 6), so the bills now are not the
# answer. The corrections' records keep each cook's cost before the
# change, and the first one that names a cook says whether they cooked.
RSpec.describe Reconciliation do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:latest) { described_class.latest_cutoff(community.today) }
  let(:admin) { create(:admin_user, community: community, superuser: true) }
  let(:ann) { create(:resident, community: community, unit: unit) }
  let(:bob) { create(:resident, community: community, unit: unit) }
  let(:cid) { create(:resident, community: community, unit: unit) }
  let(:eater) { create(:resident, community: community, unit: unit) }
  # Ann spent $30 and Bob nothing.
  let!(:meal) do
    create(:meal, community: community, date: latest - 3).tap do |meal|
      create(:bill, meal: meal, resident: ann, community: community, amount: BigDecimal('30'))
      create(:bill, meal: meal, resident: bob, community: community, amount: BigDecimal('0'), no_cost: true)
      create(:meal_resident, meal: meal, resident: eater, community: community)
    end
  end
  let!(:settled) { settle!(cutoff: latest - 3) }

  def correct(reason, &)
    MealCorrecting.save!(meal.reload, by: admin, reason: reason, &)
  end

  def settled_cooks(reconciliation = settled)
    [ann, bob, cid, eater].select { |resident| reconciliation.settled_cook?(resident) }
  end

  it 'is every cook of its dinners, a No cost cook too, when nothing was corrected' do
    expect(settled_cooks).to eq([ann, bob])
  end

  # The settlement's page lists each dinner's cooks in name order.
  it 'lists the cooks of each dinner by name (settled_cooks_by_meal)' do
    ann.update!(name: 'Zoe Ann')
    bob.update!(name: 'Abe Bob')

    expect(settled.settled_cooks_by_meal).to eq(meal.id => [bob, ann])
  end

  # Four cooks whose name order is neither their id order nor its
  # reverse, so an order that follows the rows, in either direction,
  # does not match it by chance.
  it 'lists four cooks of a dinner by name, not in the order they were added' do
    cooks = %w[Cat Abe Dee Bea].map { |name| create(:resident, community: community, unit: unit, name: "#{name} Cook") }
    later = create(:meal, community: community, date: latest)
    cooks.each do |cook|
      create(:bill, meal: later, resident: cook, community: community, amount: BigDecimal('0'), no_cost: true)
    end
    create(:meal_resident, meal: later, resident: eater, community: community)

    expect(settle!(cutoff: latest).settled_cooks_by_meal).to eq(later.id => cooks.values_at(1, 3, 0, 2))
  end

  it 'stays as it settled after a correction changes a cost, removes a cook and adds one' do
    correct('Wrong cooks') do |edits|
      edits.cost(ann, amount: BigDecimal('25'), no_cost: false)
      edits.remove_cook(bob)
      edits.cost(cid, amount: BigDecimal('5'), no_cost: false)
    end

    expect(meal.bills.reload.map(&:resident)).to contain_exactly(ann, cid)
    expect(settled_cooks).to eq([ann, bob])
  end

  # The later corrections put Bob back and take Cid off again, so their
  # bills now say the same as when the dinner settled. Only the first
  # correction that names each says what was settled, and both answers
  # here are the ones the bills give.
  it 'reads the first correction that names a cook, not the last' do
    correct('Bob did not cook') { |edits| edits.remove_cook(bob) }
    correct('Cid cooked') { |edits| edits.cost(cid, amount: BigDecimal('5'), no_cost: false) }
    correct('Bob did cook after all') { |edits| edits.cost(bob, amount: BigDecimal('0'), no_cost: true) }
    correct('Cid did not cook after all') { |edits| edits.remove_cook(cid) }

    expect(settled_cooks).to eq([ann, bob])
  end

  # DISTINCT ON keeps the first row of each dinner and cook in the
  # query's order, so the order is what makes it the first edit. Without
  # it PostgreSQL may keep any of the rows: the example above passes by
  # chance then, because its sort happens to keep the rows in id order.
  # So this reads the query itself.
  it 'orders the edits by dinner, cook, correction id and place before it keeps the first' do
    sql = described_class.settled_dinner_cooks(described_class.where(id: settled.id)).to_sql

    expect(sql).to include('ORDER BY meal_corrections.meal_id, cook_id, meal_corrections.id, cost_edit.place')
  end

  # Within one correction, the order of its record. Added and then
  # removed in one correction, Cid was no cook when the dinner settled.
  it 'reads the first edit of a correction that names a cook twice' do
    correct('Cid was never a cook') do |edits|
      edits.cost(cid, amount: BigDecimal('5'), no_cost: false)
      edits.remove_cook(cid)
      edits.cost(ann, amount: BigDecimal('25'), no_cost: false)
    end

    expect(MealCorrection.sole.edits.pluck('resident_id')).to eq([cid.id, cid.id, ann.id])
    expect(settled_cooks).to eq([ann, bob])
  end

  it 'is each settlement\'s own, and the settlement that carries a correction does not cook its dinner' do
    correct('Cid cooked') { |edits| edits.cost(cid, amount: BigDecimal('5'), no_cost: false) }
    later = create(:meal, community: community, date: latest).tap do |meal|
      create(:bill, meal: meal, resident: cid, community: community, amount: BigDecimal('12'))
      create(:meal_resident, meal: meal, resident: eater, community: community)
    end
    carrier = settle!(cutoff: latest)

    expect(carrier.meals).to eq([later])
    expect(settled_cooks(carrier)).to eq([cid])
    expect(settled_cooks).to eq([ann, bob])
  end
end
