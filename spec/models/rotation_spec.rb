# frozen_string_literal: true

# == Schema Information
#
# Table name: rotations
#
#  id                       :bigint           not null, primary key
#  color                    :string           not null
#  new_rotation_notified_at :datetime
#  place_value              :integer
#  residents_notified       :boolean          default(FALSE), not null
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
      remaining = described_class.order(:id)
      expect(remaining.pluck(:color)).to eq(Rotation::COLORS[0..3])
    end
  end

  describe '#description' do
    def rotation_with_meals(*dates)
      rotation = create(:rotation, community: community, no_email: true)
      dates.each { |date| create(:meal, community: community, rotation: rotation, date: date) }
      rotation
    end

    it 'joins day numbers with a closed-up en dash inside one month' do
      rotation = rotation_with_meals(Date.new(2026, 3, 1), Date.new(2026, 3, 15))
      expect(rotation.description).to eq('Mar 1–15, 2026')
    end

    it 'names both months and says the year once inside one year' do
      rotation = rotation_with_meals(Date.new(2026, 7, 16), Date.new(2026, 8, 13))
      expect(rotation.description).to eq('Jul 16 – Aug 13, 2026')
    end

    it 'says both years when the range crosses a year boundary' do
      rotation = rotation_with_meals(Date.new(2026, 12, 14), Date.new(2027, 1, 11))
      expect(rotation.description).to eq('Dec 14, 2026 – Jan 11, 2027')
    end

    it 'shows a single date when all meals fall on one day' do
      rotation = rotation_with_meals(Date.new(2026, 7, 16))
      expect(rotation.description).to eq('Jul 16, 2026')
    end

    it 'is blank for a rotation with no meals' do
      rotation = create(:rotation, community: community, no_email: true)

      expect(rotation.description).to eq('')
    end
  end

  describe '#start_date' do
    it 'is the first meal date' do
      rotation = create(:rotation, community: community, no_email: true)
      create(:meal, community: community, rotation: rotation, date: Date.new(2026, 4, 1))
      create(:meal, community: community, rotation: rotation, date: Date.new(2026, 4, 15))

      expect(rotation.start_date).to eq(Date.new(2026, 4, 1))
    end

    it 'is nil when the rotation has no meals' do
      rotation = create(:rotation, community: community, no_email: true)

      expect(rotation.start_date).to be_nil
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

  # Deleting upcoming rotations is how an admin applies a schedule change
  # before the calendar naturally reaches it, so these guards are what makes
  # that path safe — not only mistake protection.
  describe 'deletion' do
    let(:unit) { create(:unit, community: community) }
    let(:resident) { create(:resident, community: community, unit: unit) }

    def rotation_with_meals(*dates)
      rotation = create(:rotation, community: community, no_email: true)
      dates.each { |date| create(:meal, community: community, rotation: rotation, date: date) }
      rotation
    end

    it 'destroys an untouched upcoming rotation along with its meals' do
      rotation = rotation_with_meals(Time.zone.today + 10, Time.zone.today + 12)

      expect(rotation.destroy).to be_truthy
      expect(Meal.count).to eq(0)
    end

    it 'destroys an empty rotation' do
      rotation = create(:rotation, community: community, no_email: true)

      expect(rotation.destroy).to be_truthy
    end

    it 'refuses when a meal has an attendee, and deletes nothing' do
      rotation = rotation_with_meals(Time.zone.today + 10, Time.zone.today + 12)
      create(:meal_resident, meal: rotation.meals.first, resident: resident, community: community)

      expect(rotation.destroy).to be false
      expect(rotation.errors[:base].to_sentence).to include('attendees, cooks, or guests')
      expect(Meal.count).to eq(2)
    end

    it 'refuses when a meal has a cook (bill)' do
      rotation = rotation_with_meals(Time.zone.today + 10)
      create(:bill, meal: rotation.meals.first, resident: resident, community: community,
                    amount: BigDecimal('20'))

      expect(rotation.destroy).to be false
    end

    it 'refuses when a meal already happened' do
      rotation = rotation_with_meals(Time.zone.today - 1, Time.zone.today + 10)

      expect(rotation.destroy).to be false
      expect(rotation.errors[:base].to_sentence).to include('already happened')
    end

    it 'refuses a rotation that is not the last, so the calendar cannot get a hole' do
      early = rotation_with_meals(Time.zone.today + 10)
      rotation_with_meals(Time.zone.today + 20)

      expect(early.destroy).to be false
      expect(early.errors[:base].to_sentence).to include('Delete the newest rotation first')
    end
  end
end
