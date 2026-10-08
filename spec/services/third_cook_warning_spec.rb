# frozen_string_literal: true

require 'rails_helper'

# The rules the warning checks in order. It runs after a bills save has
# written, inside the meal lock: it is given the cooks as they were
# before the save, and reads the cooks after it from the database. The
# end-to-end behavior on the bills endpoint is in
# spec/requests/api/v1/update_bills_spec.rb.
RSpec.describe ThirdCookWarning do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:cooks) { Array.new(3) { create(:resident, community: community, unit: unit) } }
  let(:rotation) { create(:rotation, community: community) }
  let(:meal) { create(:meal, community: community, rotation: rotation, date: Date.tomorrow) }

  before do
    # Another meal in the rotation with one cook, so a third cook here
    # would be the thing the warning is about.
    short = create(:meal, community: community, rotation: rotation, date: Date.tomorrow + 1)
    create(:bill, meal: short, resident: cooks[0], community: community, amount: BigDecimal('0'))
  end

  # The save's writes: the meal's cooks after it.
  def cook_on(target, *residents)
    residents.each { |r| create(:bill, meal: target, resident: r, community: community, amount: BigDecimal('0')) }
  end

  # The past meal is in the rotation, and three cooks are new to it, so
  # every later rule would warn: only the date stops it.
  it 'says nothing for a meal that is over' do
    past = create(:meal, community: community, rotation: rotation, date: community.today - 1)
    cook_on(past, *cooks)

    expect(described_class.for(past, [])).to be_nil
  end

  it "says nothing for today's meal, which is not in the future" do
    todays = create(:meal, community: community, rotation: rotation, date: community.today)
    cook_on(todays, *cooks)

    expect(described_class.for(todays, [])).to be_nil
  end

  it 'says nothing for two cooks' do
    cook_on(meal, *cooks.first(2))

    expect(described_class.for(meal, [])).to be_nil
  end

  it 'warns when a third cook is added' do
    cook_on(meal, *cooks)

    expect(described_class.for(meal, cooks.first(2).map(&:id)))
      .to eq('Warning: third cooks should not be added until all meals in the rotation have at least two cooks.')
  end

  it 'says nothing for a third cook when every other meal in the rotation has two' do
    cook_on(Meal.where.not(id: meal.id).sole, cooks[1])
    cook_on(meal, *cooks)

    expect(described_class.for(meal, cooks.first(2).map(&:id))).to be_nil
  end

  # The cooks after the save come from the database, not from what the
  # meal has loaded: a bill the save removed may still be in the meal's
  # list in memory.
  it 'reads the cooks after the save from the database' do
    cook_on(meal, *cooks.first(2))
    meal.bills.load
    cook_on(Meal.find(meal.id), cooks[2])

    expect(described_class.for(meal, cooks.first(2).map(&:id))).to include('third cooks should not be added')
  end

  # The database returns rows in no set order: here the bills were
  # written in another order than the cooks' ids, and an updated row
  # also comes back last. The same three cooks were there before.
  it 'says nothing when the database returns the same three cooks in another order than their ids' do
    cook_on(meal, cooks[2], cooks[0], cooks[1])

    expect(described_class.for(meal, cooks.map(&:id))).to be_nil
  end

  describe 'with three cooks on the meal after the save' do
    before { cook_on(meal, *cooks) }

    it 'says nothing when the same three were there before, in another order' do
      expect(described_class.for(meal, cooks.map(&:id).reverse)).to be_nil
    end

    it 'warns when one of the three was switched for someone else' do
      other = create(:resident, community: community, unit: unit)

      expect(described_class.for(meal, [cooks[0].id, cooks[1].id, other.id]))
        .to eq('Warning: third cook should not be switched when there are other meals in the rotation ' \
               'without at least two cooks.')
    end

    it 'says nothing when a cook was removed, since nobody new is cooking' do
      other = create(:resident, community: community, unit: unit)

      expect(described_class.for(meal, cooks.map(&:id) + [other.id])).to be_nil
    end
  end
end
