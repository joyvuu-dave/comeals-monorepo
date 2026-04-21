# frozen_string_literal: true

# == Schema Information
#
# Table name: units
#
#  id           :bigint           not null, primary key
#  name         :string           not null
#  created_at   :datetime         not null
#  updated_at   :datetime         not null
#  community_id :bigint           not null
#
# Indexes
#
#  index_units_on_name  (name) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (community_id => communities.id)
#

require 'rails_helper'

RSpec.describe Unit do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }

  describe '#balance' do
    it 'returns 0 when there are no unreconciled meals' do
      expect(unit.balance).to eq(0)
    end

    it 'sums resident balances from the resident_balances cache' do
      create(:meal, community: community)
      resident_a = create(:resident, community: community, unit: unit, multiplier: 2)
      resident_b = create(:resident, community: community, unit: unit, multiplier: 2)

      ResidentBalance.create!(resident: resident_a, amount: BigDecimal('25.50'))
      ResidentBalance.create!(resident: resident_b, amount: BigDecimal('-10.00'))

      expect(unit.balance).to eq(BigDecimal('15.50'))
    end

    it 'returns 0 when all meals are reconciled' do
      reconciliation = Reconciliation.create!(community: community, end_date: Time.zone.today)
      meal = create(:meal, community: community)
      resident = create(:resident, community: community, unit: unit)
      create(:bill, meal: meal, resident: resident, community: community, amount: BigDecimal('50'))
      meal.update_column(:reconciliation_id, reconciliation.id)

      ResidentBalance.create!(resident: resident, amount: BigDecimal('50'))

      expect(unit.balance).to eq(0)
    end
  end

  describe '#meals_cooked' do
    it 'returns 0 when there are no unreconciled meals' do
      expect(unit.meals_cooked).to eq(0)
    end

    it 'counts bills for unreconciled meals across all unit residents' do
      meal_a = create(:meal, community: community)
      meal_b = create(:meal, community: community)
      resident_a = create(:resident, community: community, unit: unit)
      resident_b = create(:resident, community: community, unit: unit)

      create(:bill, meal: meal_a, resident: resident_a, community: community, amount: BigDecimal('50'))
      create(:bill, meal: meal_b, resident: resident_b, community: community, amount: BigDecimal('30'))

      expect(unit.meals_cooked).to eq(2)
    end

    it 'does not count bills for reconciled meals' do
      reconciliation = Reconciliation.create!(community: community, end_date: Time.zone.today)
      reconciled_meal = create(:meal, community: community)
      unreconciled_meal = create(:meal, community: community)
      resident = create(:resident, community: community, unit: unit)

      create(:bill, meal: reconciled_meal, resident: resident, community: community,
                    amount: BigDecimal('50'))
      create(:bill, meal: unreconciled_meal, resident: resident, community: community,
                    amount: BigDecimal('30'))
      reconciled_meal.update_column(:reconciliation_id, reconciliation.id)

      expect(unit.meals_cooked).to eq(1)
    end
  end

  describe '#number_of_occupants' do
    it 'returns the residents_count' do
      create(:resident, community: community, unit: unit)
      create(:resident, community: community, unit: unit)
      unit.reload

      expect(unit.number_of_occupants).to eq(2)
    end

    it 'returns 0 when the unit has no residents' do
      expect(unit.number_of_occupants).to eq(0)
    end
  end

  # ---------------------------------------------------------------------------
  # Real-time notifications
  # ---------------------------------------------------------------------------
  describe 'after_commit :notify_residents_update' do
    # CommunitiesController#hosts plucks `units.name` for both the dropdown
    # label and the ordering, so a Unit rename must invalidate the frontend
    # host cache. Resident callbacks do not cover this — a rename touches
    # zero Resident rows.
    let(:expected_channel) { "community-#{community.id}-residents" }

    before { allow(Pusher).to receive(:trigger) }

    it 'triggers on create' do
      create(:unit, community: community)
      expect(Pusher).to have_received(:trigger).with(
        expected_channel, 'update', hash_including(message: 'unit updated')
      ).at_least(:once)
    end

    it 'triggers on name change' do
      target = create(:unit, community: community)
      target.update!(name: "#{target.name}-renamed")
      expect(Pusher).to have_received(:trigger).with(
        expected_channel, any_args
      ).twice
    end

    it 'triggers on destroy' do
      target = create(:unit, community: community)
      target.destroy!
      expect(Pusher).to have_received(:trigger).with(
        expected_channel, any_args
      ).twice
    end

    it 'does not trigger on no-op save' do
      target = create(:unit, community: community)
      target.save!
      expect(Pusher).to have_received(:trigger).with(
        expected_channel, any_args
      ).exactly(:once)
    end

    it 'does not raise if Pusher is unavailable' do
      allow(Pusher).to receive(:trigger).and_raise(StandardError, 'pusher down')
      expect do
        create(:unit, community: community)
      end.not_to raise_error
    end
  end
end
