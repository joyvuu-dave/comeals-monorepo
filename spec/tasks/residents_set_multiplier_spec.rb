# frozen_string_literal: true

require 'rails_helper'
require 'rake'

RSpec.describe 'residents:set_multiplier' do
  before(:all) do
    RakeTasks.ensure_loaded
  end

  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }

  after do
    Rake::Task['residents:set_multiplier'].reenable
  end

  def run_task
    Rake::Task['residents:set_multiplier'].invoke
  end

  it 'reports a successful run to healthchecks' do
    allow(Healthcheck).to receive(:ping)

    run_task

    expect(Healthcheck).to have_received(:ping).with('residents-set-multiplier')
  end

  # Issue #58 moved the ages onto the community record. The column defaults
  # are 5 and 12, and with them the task must behave exactly as the old
  # hardcoded version did.
  describe 'with the default ages' do
    it 'defaults to eating free below 5 and full price from 12' do
      expect(community.free_below_age).to eq(5)
      expect(community.full_price_age).to eq(12)
    end

    it 'sets multiplier to 0 for children under 5' do
      infant = create(:resident, community: community, unit: unit,
                                 birthday: 2.years.ago.to_date, multiplier: 2)

      run_task

      expect(infant.reload.multiplier).to eq(0)
    end

    it 'sets multiplier to 1 for children aged 5 to 11' do
      child = create(:resident, community: community, unit: unit,
                                birthday: 8.years.ago.to_date, multiplier: 2)

      run_task

      expect(child.reload.multiplier).to eq(1)
    end

    it 'sets multiplier to 2 for residents aged 12 and up' do
      adult = create(:resident, community: community, unit: unit,
                                birthday: 30.years.ago.to_date, multiplier: 0)

      run_task

      expect(adult.reload.multiplier).to eq(2)
    end

    it 'handles age boundary at exactly 5' do
      exactly_5 = create(:resident, community: community, unit: unit,
                                    birthday: 5.years.ago.to_date, multiplier: 0)

      run_task

      expect(exactly_5.reload.multiplier).to eq(1)
    end

    it 'handles age boundary at exactly 12' do
      exactly_12 = create(:resident, community: community, unit: unit,
                                     birthday: 12.years.ago.to_date, multiplier: 0)

      run_task

      expect(exactly_12.reload.multiplier).to eq(2)
    end
  end

  describe 'with configured ages' do
    before { community.update!(free_below_age: 3, full_price_age: 10) }

    it 'still eats free one day before the free-below birthday' do
      # Born 3 years ago tomorrow: turns 3 tomorrow, so age is 2 today.
      almost_3 = create(:resident, community: community, unit: unit,
                                   birthday: 3.years.ago.to_date + 1.day, multiplier: 2)

      run_task

      expect(almost_3.reload.multiplier).to eq(Multiplier::FREE)
    end

    it 'moves to half price on the free-below birthday itself' do
      exactly_3 = create(:resident, community: community, unit: unit,
                                    birthday: 3.years.ago.to_date, multiplier: 2)

      run_task

      expect(exactly_3.reload.multiplier).to eq(Multiplier::HALF)
    end

    it 'still pays half price one day before the full-price birthday' do
      almost_10 = create(:resident, community: community, unit: unit,
                                    birthday: 10.years.ago.to_date + 1.day, multiplier: 2)

      run_task

      expect(almost_10.reload.multiplier).to eq(Multiplier::HALF)
    end

    it 'moves to full price on the full-price birthday itself' do
      exactly_10 = create(:resident, community: community, unit: unit,
                                     birthday: 10.years.ago.to_date, multiplier: 1)

      run_task

      expect(exactly_10.reload.multiplier).to eq(Multiplier::FULL)
    end
  end

  describe 'with equal ages (no half-price band)' do
    before { community.update!(free_below_age: 7, full_price_age: 7) }

    it 'eats free below the shared age' do
      child = create(:resident, community: community, unit: unit,
                                birthday: 6.years.ago.to_date, multiplier: 1)

      run_task

      expect(child.reload.multiplier).to eq(Multiplier::FREE)
    end

    it 'pays full price from the shared age on — nobody gets half price' do
      child = create(:resident, community: community, unit: unit,
                                birthday: 7.years.ago.to_date, multiplier: 1)

      run_task

      expect(child.reload.multiplier).to eq(Multiplier::FULL)
    end
  end

  describe 'with both ages 0' do
    before { community.update!(free_below_age: 0, full_price_age: 0) }

    it 'gives every resident with a birthday full price' do
      infant = create(:resident, community: community, unit: unit,
                                 birthday: 1.year.ago.to_date, multiplier: 0)

      run_task

      expect(infant.reload.multiplier).to eq(Multiplier::FULL)
    end
  end

  it 'skips residents with no birthday — the admin-set multiplier stands' do
    adult = create(:resident, community: community, unit: unit,
                              birthday: nil, multiplier: 2)

    run_task

    expect(adult.reload.multiplier).to eq(2)
  end

  it 'updates multiple residents in a single run' do
    infant = create(:resident, community: community, unit: unit,
                               birthday: 1.year.ago.to_date, multiplier: 2)
    child = create(:resident, community: community, unit: unit,
                              birthday: 7.years.ago.to_date, multiplier: 2)
    adult = create(:resident, community: community, unit: unit,
                              birthday: 40.years.ago.to_date, multiplier: 0)

    run_task

    expect(infant.reload.multiplier).to eq(0)
    expect(child.reload.multiplier).to eq(1)
    expect(adult.reload.multiplier).to eq(2)
  end

  describe 'logging' do
    it 'logs one line per changed resident, naming the old and new price band' do
      create(:resident, name: 'Growing Kid', community: community, unit: unit,
                        birthday: 8.years.ago.to_date, multiplier: 2)
      allow(Rails.logger).to receive(:info)

      run_task

      expect(Rails.logger).to have_received(:info)
        .with('residents:set_multiplier: Growing Kid moved from full price to half price.')
    end

    it 'logs nothing for a resident whose multiplier did not change' do
      create(:resident, name: 'Steady Adult', community: community, unit: unit,
                        birthday: 40.years.ago.to_date, multiplier: 2)
      allow(Rails.logger).to receive(:info)

      run_task

      expect(Rails.logger).not_to have_received(:info).with(/Steady Adult/)
    end
  end

  describe 'settled meals' do
    it 'does not move meal_residents.multiplier snapshots when the ages change' do
      resident = create(:resident, community: community, unit: unit,
                                   birthday: 8.years.ago.to_date, multiplier: 1)
      meal = create(:meal, community: community)
      create(:bill, meal: meal, community: community)
      attendance = create(:meal_resident, meal: meal, resident: resident, community: community)
      create(:reconciliation, community: community)
      raise 'setup failed: meal was not swept into the reconciliation' unless meal.reload.reconciled?

      # With the new ages this resident becomes full price...
      community.update!(free_below_age: 0, full_price_age: 0)
      run_task

      # ...but the settled meal keeps the snapshot taken when they attended.
      expect(resident.reload.multiplier).to eq(Multiplier::FULL)
      expect(attendance.reload.multiplier).to eq(Multiplier::HALF)
    end
  end
end
