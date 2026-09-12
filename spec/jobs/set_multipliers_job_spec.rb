# frozen_string_literal: true

require 'rails_helper'

# The rule itself, band by band, is in spec/tasks/residents_set_multiplier_spec.rb.
# This pins the bookkeeping of one run.
RSpec.describe SetMultipliersJob do
  let(:community) { create(:community, free_below_age: 5, full_price_age: 12) }
  let(:unit) { create(:unit, community: community) }

  before { allow(Healthcheck).to receive(:ping) }

  it 'counts only the residents it moved, and keeps going past the ones already right' do
    create(:resident, community: community, unit: unit, birthday: 30.years.ago.to_date, multiplier: 2)
    child = create(:resident, community: community, unit: unit, birthday: 8.years.ago.to_date, multiplier: 2)
    create(:resident, community: community, unit: unit, birthday: nil, multiplier: 2)

    described_class.perform_now

    expect(child.reload.multiplier).to eq(1)
    expect(JobRun.last.details).to eq('residents_moved' => 1)
  end

  it 'reports zero moved when everyone is already in the right band' do
    create(:resident, community: community, unit: unit, birthday: 30.years.ago.to_date, multiplier: 2)

    described_class.perform_now

    expect(JobRun.last.details).to eq('residents_moved' => 0)
  end
end
