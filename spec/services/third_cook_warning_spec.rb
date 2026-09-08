# frozen_string_literal: true

require 'rails_helper'

# The rules the warning checks in order. The end-to-end behavior on the
# bills endpoint is in spec/requests/api/v1/update_bills_spec.rb.
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

  it 'says nothing for a meal that is over' do
    expect(described_class.for(create(:meal, community: community, date: Date.yesterday), cooks.map(&:id))).to be_nil
  end

  it 'says nothing for two cooks' do
    expect(described_class.for(meal, cooks.first(2).map(&:id))).to be_nil
  end

  it 'warns when a third cook is added' do
    expect(described_class.for(meal, cooks.map(&:id))).to include('third cooks should not be added')
  end
end
