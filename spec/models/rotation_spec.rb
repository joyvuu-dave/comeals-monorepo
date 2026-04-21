# frozen_string_literal: true

# == Schema Information
#
# Table name: rotations
#
#  id                       :bigint           not null, primary key
#  color                    :string           not null
#  description              :string           default(""), not null
#  new_rotation_notified_at :datetime
#  place_value              :integer
#  residents_notified       :boolean          default(FALSE), not null
#  start_date               :date
#  created_at               :datetime         not null
#  updated_at               :datetime         not null
#  community_id             :bigint           not null
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
      rotations = Array.new(6) { create(:rotation, community: community, no_email: true) }

      # Manually break the cycle
      rotations[2].update_column(:color, rotations[1].reload.color)

      described_class.recolor_community

      reloaded_colors = rotations.map { |r| r.reload.color }
      expected = Array.new(6) { |i| Rotation::COLORS[i % Rotation::COLORS.length] }
      expect(reloaded_colors).to eq(expected)
    end

    it 'returns ids of rotations whose colors changed' do
      rotations = Array.new(3) { create(:rotation, community: community, no_email: true) }

      # Colors are already correct, so nothing should change
      changed = described_class.recolor_community
      expect(changed).to be_empty

      # Break one color
      rotations[1].update_column(:color, rotations[0].reload.color)
      changed = described_class.recolor_community
      expect(changed).to include(rotations[1].id)
    end
  end

  describe 'recolor on destroy' do
    it 'recolors remaining rotations after one is deleted' do
      rotations = Array.new(5) { create(:rotation, community: community, no_email: true) }

      # Before: green, blue, red, yellow, orange
      rotations[2].destroy!

      # After: the remaining 4 should be green, blue, red, yellow
      remaining = described_class.where(community_id: community.id).order(:id)
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

  describe '#suppress_notification_if_no_email' do
    it 'marks rotation as notified when no_email is true (suppresses rake task notification)' do
      rotation = create(:rotation, community: community, no_email: true)
      rotation.reload
      expect(rotation.new_rotation_notified_at).to be_present
    end

    it 'leaves new_rotation_notified_at nil when no_email is not set (rake task will send)' do
      rotation = described_class.new(community: community)
      expect(rotation.no_email).to be_nil
      rotation.save!
      db_val = described_class.where(id: rotation.id).pick(:new_rotation_notified_at)
      expect(db_val).to be_nil
    end
  end
end
