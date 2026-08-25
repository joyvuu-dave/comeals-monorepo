# frozen_string_literal: true

require 'rails_helper'

# The scheduled job runs the same recalculation as `rake billing:recalculate`
# (spec/tasks/billing_recalculate_spec.rb covers the math). This pins that
# the job actually calls it and records what it did.
RSpec.describe RefreshBalancesJob do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }

  it 'writes every balance from source data and records the run' do
    cook = create(:resident, community: community, unit: unit, multiplier: 2)
    eater = create(:resident, community: community, unit: unit, multiplier: 2)
    meal = create(:meal, community: community, date: Date.yesterday)
    create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('20'))
    create(:meal_resident, meal: meal, resident: eater, community: community, multiplier: 2)

    described_class.perform_now

    expect(ResidentBalance.find_by(resident: cook).amount).to eq(BigDecimal('20'))
    expect(ResidentBalance.find_by(resident: eater).amount).to eq(BigDecimal('-20'))
    run = JobRun.find_by!(name: 'refresh_balances')
    expect(run.outcome).to eq('ok')
    expect(run.details).to eq('balances_written' => 2)
  end
end
