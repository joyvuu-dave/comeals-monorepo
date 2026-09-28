# frozen_string_literal: true

require 'rails_helper'

# Promises the spec factories make, checked here so that breaking one
# fails by name, and not as a wrong number in some unrelated spec.
RSpec.describe 'the spec factories' do # rubocop:disable RSpec/DescribeClass -- checks the factories, not a class
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }

  # The resident factory turns `multiplier: 0` and `multiplier: 1` into a
  # birthday counted back from today, and the meal factory dates a meal up
  # to DefaultMealDate.days_back days back. A price is read on the meal's
  # date, so these two promises only hold together while the window is
  # short enough. A longer window or a younger factory child fails here
  # (#117).
  it 'dates default meals from yesterday back to the end of the window, and then starts again' do
    days_back = DefaultMealDate.days_back

    expect(DefaultMealDate.for(1)).to eq(1.day.ago.to_date)
    expect(DefaultMealDate.for(days_back)).to eq(days_back.days.ago.to_date)
    expect(DefaultMealDate.for(days_back + 1)).to eq(1.day.ago.to_date)
  end

  [1, DefaultMealDate.days_back].each do |n|
    it "gives each factory price band its own price on a default meal #{n} days back" do
      meal = create(:meal, community: community, date: DefaultMealDate.for(n))

      prices = [Multiplier::FREE, Multiplier::HALF, Multiplier::FULL].to_h do |band|
        resident = create(:resident, community: community, unit: unit, multiplier: band)
        [band, create(:meal_resident, meal: meal, resident: resident, community: community).multiplier]
      end

      expect(prices).to eq(Multiplier::FREE => Multiplier::FREE,
                           Multiplier::HALF => Multiplier::HALF,
                           Multiplier::FULL => Multiplier::FULL)
    end
  end

  # There is only ever one community row, so the community factory reuses
  # it. Every other factory asks for a community too (a unit, a meal, an
  # event), and that must not write the community factory's defaults back
  # onto a row a spec has changed.
  describe 'the community factory' do
    it "leaves the one community's name and time zone alone when another factory asks for it" do
      create(:community, name: 'Kauai Commons', timezone: 'Pacific/Honolulu')

      create(:event)
      create(:resident)
      create(:meal)

      expect(Community.sole).to have_attributes(name: 'Kauai Commons', timezone: 'Pacific/Honolulu')
    end

    it 'writes only what the caller gives onto the existing row' do
      first = create(:community, name: 'Kauai Commons', timezone: 'Pacific/Honolulu')

      again = create(:community, cap: BigDecimal('4.50'))

      expect(again).to eq(first)
      expect(Community.sole).to have_attributes(name: 'Kauai Commons', timezone: 'Pacific/Honolulu',
                                                cap: BigDecimal('4.50'))
    end

    it 'makes the row with its defaults when there is none' do
      expect(create(:community)).to have_attributes(name: 'Test Community', timezone: 'America/Los_Angeles')
    end
  end

  # The admin run page reads LedgerVerification's details back, and its
  # page specs and the admin screenshots build them with this trait, so
  # the trait must have the shape a real failing run writes.
  describe 'the ledger check run factory' do
    it 'builds :with_mismatches details with the keys a real failing run writes' do
      cook = create(:resident, community: community, unit: unit)
      eater = create(:resident, community: community, unit: unit)
      meal = create(:meal, community: community)
      create(:bill, meal: meal, resident: cook, amount: BigDecimal('50'))
      create(:meal_resident, meal: meal, resident: cook)
      create(:meal_resident, meal: meal, resident: eater)
      balances = settle!.reconciliation_balances.to_a
      # Move a dollar between the two stored balances behind the guards, so
      # the recompute check disagrees and the sums still balance.
      ActiveRecord::Base.transaction do
        ActiveRecord::Base.connection.execute("SET LOCAL comeals.allow_settled_writes = 'on'")
        ReconciliationBalance.where(id: balances.first.id).update_all(amount: balances.first.amount + 1)
        ReconciliationBalance.where(id: balances.last.id).update_all(amount: balances.last.amount - 1)
      end

      run = begin
        LedgerVerification.call
      rescue LedgerVerification::MismatchError => e
        e.run
      end
      real = run.reload.details.find { |detail| detail['check'] == 'recompute' }
      built = build(:ledger_check_run, :with_mismatches).details.sole

      expect(built.keys).to match_array(real.keys)
      expect(built['check']).to eq(real['check'])
      expect(built['differences'].map(&:keys)).to all(match_array(real['differences'].first.keys))
    end
  end
end
