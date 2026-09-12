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

    # Place is by first meal date, and it is only recomputed when a
    # rotation is created or destroyed. A rotation whose place changes
    # gets a new updated_at (the calendar's version reads it) and its
    # months are pushed; one whose place is already right is not touched.
    it 'renumbers by first meal date when a rotation is created, telling the months it renumbered' do
      r1 = create(:rotation, community: community, no_email: true)
      r2 = create(:rotation, community: community, no_email: true)
      create(:meal, community: community, rotation: r1, date: Date.new(2027, 6, 15))
      create(:meal, community: community, rotation: r2, date: Date.new(2027, 4, 15))
      expect([r1, r2].map { |rotation| rotation.reload.place_value }).to eq([1, 2])
      stamps = [r1, r2].map(&:updated_at)
      pushed = []
      RSpec::Mocks.space.proxy_for(Pusher).reset
      allow(Pusher).to receive(:trigger) { |channel, *| pushed << channel }

      r3 = create(:rotation, community: community, no_email: true)

      expect([r2, r1, r3].map { |rotation| rotation.reload.place_value }).to eq([1, 2, 3])
      expect(r1.updated_at).to be > stamps[0]
      expect(r2.updated_at).to be > stamps[1]
      expect(pushed).to include(community.calendar_cache_key(2027, 4), community.calendar_cache_key(2027, 6))
    end

    it 'leaves a rotation whose place is already right alone' do
      r1 = create(:rotation, community: community, no_email: true)
      create(:meal, community: community, rotation: r1, date: Date.new(2027, 4, 15))
      stamp = r1.reload.updated_at
      pushed = []
      RSpec::Mocks.space.proxy_for(Pusher).reset
      allow(Pusher).to receive(:trigger) { |channel, *| pushed << channel }

      create(:rotation, community: community, no_email: true)

      expect(r1.reload.updated_at).to eq(stamp)
      expect(pushed).not_to include(community.calendar_cache_key(2027, 4))
    end
  end

  describe '.starting_within' do
    def rotation_starting(*dates)
      rotation = create(:rotation, community: community, no_email: true)
      dates.each { |date| create(:meal, community: community, rotation: rotation, date: date) }
      rotation
    end

    it 'takes the rotations whose first meal is in the range, start included and end excluded' do
      rotation_starting(Date.new(2026, 4, 1), Date.new(2026, 4, 8)) # first meal before the range
      on_start = rotation_starting(Date.new(2026, 4, 5), Date.new(2026, 4, 20))
      inside = rotation_starting(Date.new(2026, 4, 11), Date.new(2026, 4, 13))
      rotation_starting(Date.new(2026, 4, 12), Date.new(2026, 4, 14)) # first meal on the excluded end
      create(:rotation, community: community, no_email: true) # no meals at all

      found = described_class.starting_within(Date.new(2026, 4, 5)...Date.new(2026, 4, 12))

      expect(found).to contain_exactly(on_start, inside)
    end
  end

  describe '#touched_meals' do
    let(:unit) { create(:unit, community: community) }
    let(:resident) { create(:resident, community: community, unit: unit, multiplier: 2) }
    let(:today) { community.today }

    it 'is every meal that happened, is closed or settled, or has a bill, an attendee or a guest' do
      rotation = create(:rotation, community: community, no_email: true)
      meal = ->(days) { create(:meal, community: community, rotation: rotation, date: today + days) }
      meal.call(1) # tomorrow: untouched
      meal.call(2) # untouched
      happened = meal.call(0) # today counts as happened
      closed = meal.call(3).tap { |m| m.update!(closed: true, max: 0) }
      with_bill = meal.call(4).tap do |m|
        create(:bill, meal: m, resident: resident, community: community, amount: BigDecimal('10'))
      end
      with_attendee = meal.call(5).tap { |m| create(:meal_resident, meal: m, resident: resident, community: community) }
      with_guest = meal.call(6).tap { |m| create(:guest, meal: m, resident: resident) }
      settled = meal.call(7).tap { |m| m.update!(reconciliation: create(:reconciliation, community: community)) }
      other = create(:rotation, community: community, no_email: true)
      create(:meal, community: community, rotation: other, date: today - 1)

      expect(rotation.touched_meals).to contain_exactly(happened, closed, with_bill, with_attendee, with_guest,
                                                        settled)
    end
  end

  describe 'refusing to leave a hole (reject_destroy_unless_last)' do
    let(:today) { community.today }

    it 'refuses when another rotation has a meal the very next day after its last meal' do
      first = create(:rotation, community: community, no_email: true)
      create(:meal, community: community, rotation: first, date: today + 10)
      second = create(:rotation, community: community, no_email: true)
      create(:meal, community: community, rotation: second, date: today + 11)

      expect { first.destroy }.not_to change(described_class, :count)
      expect(first.errors[:base].join).to include('Delete the newest rotation first')
    end
  end

  describe 'telling the calendar (note_live_update)' do
    def calendar_channels_pushed
      RSpec::Mocks.space.proxy_for(Pusher).reset
      pushed = []
      allow(Pusher).to receive(:trigger) { |channel, *| pushed << channel }
      yield
      pushed.select { |channel| channel.include?('-calendar-') }
    end

    # Mid-month dates, so no other month's six-week calendar shows them.
    it 'pushes every month its meals fall in when it is saved, and no other rotation\'s' do
      rotation = create(:rotation, community: community, no_email: true)
      create(:meal, community: community, rotation: rotation, date: Date.new(2027, 4, 15))
      create(:meal, community: community, rotation: rotation, date: Date.new(2027, 6, 15))
      other = create(:rotation, community: community, no_email: true)
      create(:meal, community: community, rotation: other, date: Date.new(2027, 8, 15))

      pushed = calendar_channels_pushed { rotation.update!(color: Rotation::COLORS.last) }

      expect(pushed).to contain_exactly(community.calendar_cache_key(2027, 4), community.calendar_cache_key(2027, 6))
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

    it 'pushes the months of the rotations whose color changed, and not of one that kept its color' do
      rotations = Array.new(5) { create(:rotation, community: community, no_email: true) }
      create(:meal, community: community, rotation: rotations[0], date: Date.new(2027, 4, 15))
      create(:meal, community: community, rotation: rotations[4], date: Date.new(2027, 8, 15))
      pushed = []
      RSpec::Mocks.space.proxy_for(Pusher).reset
      allow(Pusher).to receive(:trigger) { |channel, *| pushed << channel }

      rotations[2].destroy!

      expect(pushed).to include(community.calendar_cache_key(2027, 8))
      expect(pushed).not_to include(community.calendar_cache_key(2027, 4))
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
