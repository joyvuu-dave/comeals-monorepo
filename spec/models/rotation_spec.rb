# frozen_string_literal: true

# == Schema Information
#
# Table name: rotations
#
#  id                 :bigint           not null, primary key
#  color              :string           not null
#  description        :string           default(""), not null
#  place_value        :integer
#  residents_notified :boolean          default(FALSE), not null
#  start_date         :date
#  created_at         :datetime         not null
#  updated_at         :datetime         not null
#  community_id       :bigint           not null
#
# Indexes
#
#  index_rotations_on_community_id  (community_id)
#
# Foreign Keys
#
#  fk_rails_...  (community_id => communities.id)
#
require 'rails_helper'

RSpec.describe Rotation do
  let(:community) { create(:community) }

  describe '#set_place_value' do
    it 'assigns sequential place_values scoped to community' do
      r1 = create(:rotation, community: community, no_email: true)
      r2 = create(:rotation, community: community, no_email: true)

      expect(r1.reload.place_value).to eq(1)
      expect(r2.reload.place_value).to eq(2)
    end

    it 'does not renumber rotations in other communities' do
      other_community = create(:community)
      other_rotation = create(:rotation, community: other_community, no_email: true)
      original_place = other_rotation.reload.place_value

      # Creating a rotation in our community should not affect the other community
      create(:rotation, community: community, no_email: true)

      expect(other_rotation.reload.place_value).to eq(original_place)
    end

    it 'reorders on destroy' do
      r1 = create(:rotation, community: community, no_email: true)
      r2 = create(:rotation, community: community, no_email: true)
      r3 = create(:rotation, community: community, no_email: true)

      r2.destroy!
      expect(r1.reload.place_value).to eq(1)
      expect(r3.reload.place_value).to eq(2)
    end
  end

  describe '#set_color' do
    it 'cycles through all five colors in order' do
      colors = []
      6.times do
        r = create(:rotation, community: community, no_email: true)
        colors << r.color
      end

      expect(colors).to eq(Rotation::COLORS + [Rotation::COLORS[0]])
    end

    it 'picks the next color after the last rotation' do
      create(:rotation, community: community, no_email: true) # green
      create(:rotation, community: community, no_email: true) # blue
      r3 = create(:rotation, community: community, no_email: true)

      expect(r3.color).to eq(Rotation::COLORS[2])
    end

    it 'assigns the first color when no rotations exist' do
      r = create(:rotation, community: community, no_email: true)
      expect(r.color).to eq(Rotation::COLORS[0])
    end
  end

  describe '.recolor_community' do
    it 'reassigns colors in COLORS-cycle order by id' do
      rotations = 6.times.map { create(:rotation, community: community, no_email: true) }

      # Manually break the cycle
      rotations[2].update_column(:color, rotations[1].reload.color)

      Rotation.recolor_community(community.id)

      reloaded_colors = rotations.map { |r| r.reload.color }
      expected = 6.times.map { |i| Rotation::COLORS[i % Rotation::COLORS.length] }
      expect(reloaded_colors).to eq(expected)
    end

    it 'returns ids of rotations whose colors changed' do
      rotations = 3.times.map { create(:rotation, community: community, no_email: true) }

      # Colors are already correct, so nothing should change
      changed = Rotation.recolor_community(community.id)
      expect(changed).to be_empty

      # Break one color
      rotations[1].update_column(:color, rotations[0].reload.color)
      changed = Rotation.recolor_community(community.id)
      expect(changed).to include(rotations[1].id)
    end

    it 'does not affect rotations in other communities' do
      other_community = create(:community)
      other_rotation = create(:rotation, community: other_community, no_email: true)
      original_color = other_rotation.color

      create(:rotation, community: community, no_email: true)
      Rotation.recolor_community(community.id)

      expect(other_rotation.reload.color).to eq(original_color)
    end
  end

  describe 'recolor on destroy' do
    it 'recolors remaining rotations after one is deleted' do
      rotations = 5.times.map { create(:rotation, community: community, no_email: true) }

      # Before: green, blue, red, yellow, orange
      rotations[2].destroy!

      # After: the remaining 4 should be green, blue, red, yellow
      remaining = Rotation.where(community_id: community.id).order(:id)
      expect(remaining.pluck(:color)).to eq(Rotation::COLORS[0..3])
    end
  end

  describe '#set_description' do
    it 'sets description to the date range of meals' do
      rotation = create(:rotation, community: community, no_email: true)
      create(:meal, community: community, rotation: rotation, date: Date.new(2026, 3, 1))
      create(:meal, community: community, rotation: rotation, date: Date.new(2026, 3, 15))

      rotation.save!
      expect(rotation.reload.description).to include('2026')
    end

    it 'handles a rotation with no meals' do
      rotation = create(:rotation, community: community, no_email: true)

      rotation.save!
      expect(rotation.reload.description).to eq(' to ')
    end
  end

  describe '#set_start_date' do
    it 'sets start_date from the first meal date' do
      rotation = create(:rotation, community: community, no_email: true)
      create(:meal, community: community, rotation: rotation, date: Date.new(2026, 4, 1))
      create(:meal, community: community, rotation: rotation, date: Date.new(2026, 4, 15))

      rotation.save!
      expect(rotation.reload.start_date).to eq(Date.new(2026, 4, 1))
    end

    it 'sets start_date to nil when rotation has no meals' do
      rotation = create(:rotation, community: community, no_email: true)

      rotation.save!
      expect(rotation.reload.start_date).to be_nil
    end
  end

  describe '#meals_count' do
    it 'returns the number of meals in the rotation' do
      rotation = create(:rotation, community: community, no_email: true)
      create(:meal, community: community, rotation: rotation)
      create(:meal, community: community, rotation: rotation)

      expect(rotation.meals_count).to eq(2)
    end
  end

  describe '#notify_residents' do
    let(:unit) { create(:unit, community: community) }

    it 'does not send emails when no_email is true' do
      create(:resident, community: community, unit: unit, email: 'test@example.com')
      expect do
        create(:rotation, community: community, no_email: true)
      end.not_to(change { ActionMailer::Base.deliveries.count })
    end

    it 'skips inactive residents' do
      create(:resident, community: community, unit: unit, active: false)
      create(:resident, community: community, unit: unit, active: true)

      expect do
        create(:rotation, community: community, no_email: false)
      end.to change { ActionMailer::Base.deliveries.count }.by(1)
    end
  end
end
