# frozen_string_literal: true

# == Schema Information
#
# Table name: communities
#
#  id                   :bigint           not null, primary key
#  cap                  :decimal(12, 8)
#  meals_per_rotation   :integer          default(12), not null
#  name                 :string           not null
#  schedule             :jsonb            not null
#  schedule_anchor_date :date             not null
#  singleton_guard      :integer          default(0), not null
#  slug                 :string           not null
#  timezone             :string           not null
#  created_at           :datetime         not null
#  updated_at           :datetime         not null
#
# Indexes
#
#  index_communities_on_name             (name) UNIQUE
#  index_communities_on_singleton_guard  (singleton_guard) UNIQUE
#  index_communities_on_slug             (slug) UNIQUE
#
require 'rails_helper'

RSpec.describe Community do
  let(:community) { create(:community, cap: BigDecimal('4.50')) }
  let(:unit) { create(:unit, community: community) }

  describe 'singleton enforcement' do
    it 'prevents creating a second community' do
      community # ensure the singleton exists
      second = described_class.new(name: 'Another Community')

      expect(second).not_to be_valid
      expect(second.errors[:base]).to include('Only one Community record is allowed')
    end

    it 'prevents destruction' do
      expect(community.destroy).to be false
      expect(described_class.count).to eq(1)
    end
  end

  describe 'timezone' do
    # The DB column default was dropped (see 20260423170000 migration) so
    # operators must explicitly pick a tz at create time. This prevents
    # silently deploying a Berlin community on Pacific time.
    it 'requires a timezone at creation' do
      community_without_tz = described_class.new(name: 'No TZ', slug: 'no-tz', timezone: nil)

      expect(community_without_tz).not_to be_valid
      expect(community_without_tz.errors[:timezone]).to be_present
    end

    it 'accepts any timezone from SUPPORTED_TIMEZONES' do
      Community::SUPPORTED_TIMEZONES.each_value do |iana|
        c = described_class.new(name: 'Fixture', slug: 'fixture', timezone: iana)
        c.valid?
        expect(c.errors[:timezone]).to be_empty, "expected #{iana} to be accepted"
      end
    end
  end

  describe '.instance' do
    it 'returns the existing community' do
      community # ensure the singleton exists
      expect(described_class.instance).to eq(community)
    end

    it 'raises when no community exists' do
      expect { described_class.instance }.to raise_error(RuntimeError, /No Community record exists/)
    end

    it 'caches the result per-request via Current' do
      community # ensure the singleton exists
      described_class.instance
      expect(Current.community).to eq(community)
    end
  end

  describe '#unreconciled_ave_cost' do
    it 'returns average cost per adult for unreconciled meals' do
      cook = create(:resident, community: community, unit: unit, multiplier: 2)
      diner = create(:resident, community: community, unit: unit, multiplier: 2)

      meal = create(:meal, community: community)
      create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('16'))
      create(:meal_resident, meal: meal, resident: cook, community: community)
      create(:meal_resident, meal: meal, resident: diner, community: community)

      result = community.unreconciled_ave_cost
      # total_multiplier = 2 + 2 = 4, total_cost = 16 (under the 4.50/unit cap),
      # cost_per_unit = 4, per_adult = 8
      expect(result).to eq('$8.00/adult')
    end

    # Settlement rule: a subsidized meal charges only its effective (capped)
    # cost — cap * multiplier — not the raw bill total.
    it 'uses the effective capped cost for subsidized meals' do
      cook = create(:resident, community: community, unit: unit, multiplier: 2)
      diner = create(:resident, community: community, unit: unit, multiplier: 2)

      meal = create(:meal, community: community)
      create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('40'))
      create(:meal_resident, meal: meal, resident: cook, community: community)
      create(:meal_resident, meal: meal, resident: diner, community: community)

      # cap 4.50 * multiplier 4 = 18 effective (raw 40); 2 * (18 / 4) = $9.00
      expect(community.unreconciled_ave_cost).to eq('$9.00/adult')
    end

    it 'returns -- when no unreconciled meals exist' do
      expect(community.unreconciled_ave_cost).to eq('--')
    end

    it 'returns -- when total multiplier is zero' do
      child = create(:resident, community: community, unit: unit, multiplier: 0)
      meal = create(:meal, community: community)
      create(:bill, meal: meal, resident: child, community: community, amount: BigDecimal('10'))
      create(:meal_resident, meal: meal, resident: child, community: community, multiplier: 0)

      expect(community.unreconciled_ave_cost).to eq('--')
    end

    # Settlement rule: a bill on a meal nobody attended has zero financial
    # impact (the cook absorbs it). The dashboard average must skip it too.
    it 'excludes bills from meals with no attendees' do
      cook = create(:resident, community: community, unit: unit, multiplier: 2)
      diner = create(:resident, community: community, unit: unit, multiplier: 2)

      attended = create(:meal, community: community)
      create(:bill, meal: attended, resident: cook, community: community, amount: BigDecimal('16'))
      create(:meal_resident, meal: attended, resident: cook, community: community)
      create(:meal_resident, meal: attended, resident: diner, community: community)

      empty = create(:meal, community: community)
      create(:bill, meal: empty, resident: cook, community: community, amount: BigDecimal('60'))

      # Only the attended meal counts: 2 * (16 / 4) = $8.00
      expect(community.unreconciled_ave_cost).to eq('$8.00/adult')
    end

    # Settlement rule (the total_mult.zero? short-circuit in billing:recalculate):
    # a meal whose attendees sum to zero multiplier charges nobody, so its
    # bills add nothing — even when the meal is uncapped.
    it 'excludes bills from zero-multiplier meals' do
      cook = create(:resident, community: community, unit: unit, multiplier: 2)
      diner = create(:resident, community: community, unit: unit, multiplier: 2)
      child = create(:resident, community: community, unit: unit, multiplier: 0)

      attended = create(:meal, community: community)
      create(:bill, meal: attended, resident: cook, community: community, amount: BigDecimal('16'))
      create(:meal_resident, meal: attended, resident: cook, community: community)
      create(:meal_resident, meal: attended, resident: diner, community: community)

      child_only = create(:meal, community: community)
      child_only.update!(cap: nil) # uncapped, so the cap can't mask the rule
      create(:bill, meal: child_only, resident: cook, community: community, amount: BigDecimal('10'))
      create(:meal_resident, meal: child_only, resident: child, community: community, multiplier: 0)

      # Only the attended meal contributes cost: 2 * (16 / 4) = $8.00
      expect(community.unreconciled_ave_cost).to eq('$8.00/adult')
    end
  end

  describe '#unreconciled_ave_number_of_attendees' do
    it 'returns average attendee count across unreconciled meals' do
      cook = create(:resident, community: community, unit: unit, multiplier: 2)
      diner = create(:resident, community: community, unit: unit, multiplier: 2)

      meal1 = create(:meal, community: community)
      create(:meal_resident, meal: meal1, resident: cook, community: community)
      create(:meal_resident, meal: meal1, resident: diner, community: community)

      meal2 = create(:meal, community: community)
      create(:meal_resident, meal: meal2, resident: cook, community: community)

      # meal1: 2 attendees, meal2: 1 attendee, average = 1.5
      expect(community.unreconciled_ave_number_of_attendees).to eq(1.5)
    end

    it 'returns -- when no unreconciled meals exist' do
      expect(community.unreconciled_ave_number_of_attendees).to eq('--')
    end

    it 'counts guests in addition to residents' do
      cook = create(:resident, community: community, unit: unit, multiplier: 2)
      meal = create(:meal, community: community)
      create(:meal_resident, meal: meal, resident: cook, community: community)
      create(:guest, meal: meal, resident: cook)

      # 1 resident + 1 guest = 2 attendees / 1 meal = 2.0
      expect(community.unreconciled_ave_number_of_attendees).to eq(2.0)
    end
  end

  describe '#capped?' do
    it 'returns true when cap is set' do
      expect(community.capped?).to be true
    end

    it 'returns false when cap is nil' do
      community.update!(cap: nil)
      expect(community.capped?).to be false
    end
  end

  # Both bounds exist because the database rejected these values with an
  # exception, which reached the admin as a 500 page instead of a form error.
  # Zero and negative hit the communities_cap_positive_or_null check
  # constraint; anything over 9999.99999999 overflows the DECIMAL(12, 8)
  # column. The model now refuses them first.
  describe 'cap bounds' do
    it 'allows a blank cap, which means no cap' do
      community.cap = nil
      expect(community).to be_valid
    end

    it 'allows one cent, the smallest amount of real money' do
      community.cap = BigDecimal('0.01')
      expect(community).to be_valid
    end

    it 'allows an ordinary cap' do
      community.cap = BigDecimal('4.50')
      expect(community).to be_valid
    end

    it 'allows the largest whole-cent amount the column can hold' do
      community.cap = BigDecimal('9999.99')
      expect(community).to be_valid
    end

    it 'refuses zero' do
      community.cap = BigDecimal('0')
      expect(community).not_to be_valid
      expect(community.errors[:cap]).to include('must be at least $0.01, or blank for no cap')
    end

    it 'refuses a negative cap' do
      community.cap = BigDecimal('-5')
      expect(community).not_to be_valid
      expect(community.errors[:cap]).to include('must be at least $0.01, or blank for no cap')
    end

    it 'refuses a fraction of a cent' do
      community.cap = BigDecimal('0.001')
      expect(community).not_to be_valid
      expect(community.errors[:cap]).to include('must be at least $0.01, or blank for no cap')
    end

    it 'refuses a value too large for the column' do
      community.cap = BigDecimal('10000')
      expect(community).not_to be_valid
      expect(community.errors[:cap]).to include('must be $9,999.99 or less')
    end

    # Under $10,000, so a "less than 10000" bound would have let this through.
    # The column has 8 decimal places, so it rounds to 10000.00000000 and
    # overflows. A whole-cent ceiling cannot be rounded past.
    it 'refuses a value that rounds up past the column maximum' do
      community.cap = BigDecimal('9999.999999996')
      expect(community).not_to be_valid
      expect(community.errors[:cap]).to include('must be $9,999.99 or less')
    end

    it 'saves without raising instead of hitting the database constraint' do
      expect { community.update(cap: BigDecimal('0')) }.not_to raise_error
      expect(community.reload.cap).to eq(BigDecimal('4.50'))
    end

    it 'saves without raising instead of overflowing the column' do
      expect { community.update(cap: BigDecimal('10000')) }.not_to raise_error
      expect(community.reload.cap).to eq(BigDecimal('4.50'))
    end
  end

  describe 'meal schedule config' do
    it 'starts with the classic schedule from the column defaults' do
      expect(community.schedule).to eq([[0, 1, 4], [0, 2, 4]])
      expect(community.meals_per_rotation).to eq(12)
      expect(community).to be_valid
    end

    it 'normalizes the admin form hash, keeping empty weeks' do
      community.schedule = { '1' => [''], '0' => ['', '4', '0', '4'] }
      expect(community.schedule).to eq([[0, 4], []])
      expect(community).to be_valid
    end

    it 'refuses a schedule with no meal days at all' do
      community.schedule = [[], []]
      expect(community).not_to be_valid
      expect(community.errors[:schedule]).to include('must include at least one meal day')
    end

    it 'refuses a cycle outside 1 to 6 weeks' do
      community.schedule = []
      expect(community).not_to be_valid
      expect(community.errors[:schedule]).to include('must have between 1 and 6 weeks')

      community.schedule = Array.new(7) { [0] }
      expect(community).not_to be_valid
      expect(community.errors[:schedule]).to include('must have between 1 and 6 weeks')
    end

    it 'refuses days outside Sunday through Saturday' do
      community.schedule = [[0, 7]]
      expect(community).not_to be_valid
      expect(community.errors[:schedule]).to include('days must be 0 (Sunday) through 6 (Saturday)')
    end

    it 'reports rather than raises on uncoercible form input' do
      community.schedule = { '0' => %w[banana 0] }
      expect(community).not_to be_valid
      expect(community.errors[:schedule]).to include('days must be 0 (Sunday) through 6 (Saturday)')
    end

    it 'refuses a meals_per_rotation outside 1 to 100' do
      [0, -3, 101, 2.5].each do |bad|
        community.meals_per_rotation = bad
        expect(community).not_to be_valid
        expect(community.errors[:meals_per_rotation]).to include('must be a whole number from 1 to 100')
      end
    end

    it 'normalizes the anchor to the Sunday of its week' do
      community.schedule_anchor_date = Date.new(2026, 8, 5) # a Wednesday
      expect(community).to be_valid
      expect(community.schedule_anchor_date).to eq(Date.new(2026, 8, 2))
    end

    it 'requires an anchor on an existing record' do
      community.schedule_anchor_date = nil
      expect(community).not_to be_valid
    end

    it 'defaults the anchor to the current week on create' do
      fresh = described_class.new(name: 'Fresh', timezone: 'America/Los_Angeles')
      fresh.valid?
      expect(fresh.schedule_anchor_date).to eq(Time.zone.today.beginning_of_week(:sunday))
    end

    it 'saves without raising instead of hitting the database constraint' do
      expect { community.update(schedule: [[], []]) }.not_to raise_error
      expect(community.reload.schedule).to eq([[0, 1, 4], [0, 2, 4]])
    end

    it '#meal_schedule wraps the columns' do
      schedule = community.meal_schedule
      expect(schedule).to be_a(MealSchedule)
      expect(schedule.weeks).to eq(community.schedule)
      expect(schedule.anchor_date).to eq(community.schedule_anchor_date)
    end
  end

  describe '#auto_rotation_length' do
    it 'calculates half the number of cookable adults' do
      4.times { create(:resident, community: community, unit: unit, multiplier: 2, can_cook: true) }
      2.times { create(:resident, community: community, unit: unit, multiplier: 1, can_cook: true) }
      # 4 adults (multiplier >= 2) who can cook, divided by 2 = 2
      expect(community.auto_rotation_length).to eq(2)
    end
  end

  describe '#auto_create_rotations' do
    it 'groups unassigned meals into rotations based on auto_rotation_length' do
      # Need cookable adults for auto_rotation_length to be > 0
      4.times { create(:resident, community: community, unit: unit, multiplier: 2, can_cook: true) }
      # auto_rotation_length = 4/2 = 2

      create(:meal, community: community, date: Date.new(2026, 5, 1))
      create(:meal, community: community, date: Date.new(2026, 5, 3))
      create(:meal, community: community, date: Date.new(2026, 5, 5))

      community.auto_create_rotations

      # 3 meals with rotation_length 2 = 2 rotations (2 + 1)
      expect(community.rotations.count).to eq(2)
      expect(Meal.where(community: community, rotation_id: nil).count).to eq(0)
    end
  end

  describe '#create_next_rotation' do
    it 'creates a rotation with meals_per_rotation meals' do
      # Need cookable adults
      4.times { create(:resident, community: community, unit: unit, multiplier: 2, can_cook: true) }

      community.create_next_rotation

      expect(community.rotations.count).to eq(1)
      expect(community.meals.count).to eq(community.meals_per_rotation)
    end

    it 'creates meals only on days the schedule allows' do
      4.times { create(:resident, community: community, unit: unit, multiplier: 2, can_cook: true) }

      community.create_next_rotation

      allowed = community.schedule.flatten.uniq
      wdays = community.meals.pluck(:date).map(&:wday)
      expect(wdays).to all(be_in(allowed))
    end

    it 'follows a changed schedule on the next run' do
      community.update!(schedule: [[3]]) # Wednesdays only

      community.create_next_rotation

      expect(community.meals.pluck(:date).map(&:wday)).to all(eq(3))
    end

    # The dates below are what the old hard-coded algorithm produced for the
    # same starting state (computed from it before it was deleted). The anchor
    # matches what the migration backfill derives from the last Monday-or-
    # Tuesday meal, so this pins "the first rotation generated after deploy
    # matches what the old code would have created" — including which of the
    # alternating days comes next.
    describe 'equivalence with the old algorithm' do
      include ActiveSupport::Testing::TimeHelpers

      let(:rotation) { create(:rotation, community: community) }

      it 'continues the alternation when the last alternating meal was a Monday' do
        travel_to Date.new(2026, 8, 7) do
          create(:meal, community: community, date: Date.new(2026, 8, 3), rotation_id: rotation.id)
          # Backfill rule: a Monday meal's week is a week-1 week.
          community.update!(schedule_anchor_date: Date.new(2026, 8, 2))

          community.create_next_rotation

          expect(community.meals.where.not(rotation_id: rotation.id)
                          .order(:date).pluck(:date)).to eq [
                            Date.new(2026, 8, 9), Date.new(2026, 8, 11), Date.new(2026, 8, 13),
                            Date.new(2026, 8, 16), Date.new(2026, 8, 17), Date.new(2026, 8, 20),
                            Date.new(2026, 8, 23), Date.new(2026, 8, 25), Date.new(2026, 8, 27),
                            Date.new(2026, 8, 30), Date.new(2026, 8, 31), Date.new(2026, 9, 3)
                          ]
        end
      end

      it 'continues the alternation when the last alternating meal was a Tuesday' do
        travel_to Date.new(2026, 8, 7) do
          create(:meal, community: community, date: Date.new(2026, 8, 4), rotation_id: rotation.id)
          # Backfill rule: a Tuesday meal's week is a week-2 week, so week 1
          # was the week before.
          community.update!(schedule_anchor_date: Date.new(2026, 7, 26))

          community.create_next_rotation

          expect(community.meals.where.not(rotation_id: rotation.id)
                          .order(:date).pluck(:date)).to eq [
                            Date.new(2026, 8, 9), Date.new(2026, 8, 10), Date.new(2026, 8, 13),
                            Date.new(2026, 8, 16), Date.new(2026, 8, 18), Date.new(2026, 8, 20),
                            Date.new(2026, 8, 23), Date.new(2026, 8, 24), Date.new(2026, 8, 27),
                            Date.new(2026, 8, 30), Date.new(2026, 9, 1), Date.new(2026, 9, 3)
                          ]
        end
      end

      it 'keeps the phase across consecutive rotations' do
        travel_to Date.new(2026, 8, 7) do
          community.update!(schedule_anchor_date: Date.new(2026, 8, 2))

          community.create_next_rotation
          community.create_next_rotation

          # Mondays and Tuesdays must strictly alternate across the rotation
          # boundary — the old code got this from meal history, the new code
          # from anchor arithmetic.
          alternating = community.meals.order(:date).pluck(:date).map(&:wday).select { |d| [1, 2].include?(d) }
          alternating.each_cons(2) { |a, b| expect(a).not_to eq(b) }
        end
      end
    end

    it 'raises when unassigned meals exist' do
      create(:meal, community: community)

      expect { community.create_next_rotation }.to raise_error(RuntimeError, /not assigned to Rotations/)
    end

    it 'sets start_date and description on the created rotation' do
      4.times { create(:resident, community: community, unit: unit, multiplier: 2, can_cook: true) }

      community.create_next_rotation

      rotation = community.rotations.first
      first_meal_date = rotation.meals.order(:date).first.date
      last_meal_date = rotation.meals.order(:date).last.date

      expect(rotation.start_date).to eq(first_meal_date)
      # The exact wording of the range is Rotation's concern
      # (spec/models/rotation_spec.rb); here it is enough that the
      # description was filled in from the meal dates.
      expect(rotation.description).to eq(rotation.date_range_description)
      expect(rotation.description).to include(last_meal_date.strftime('%-d'))
    end
  end

  describe '#trigger_pusher' do
    before do
      allow(Rails.cache).to receive(:delete)
    end

    it 'triggers pusher notifications and clears cache' do
      community.trigger_pusher(Date.new(2026, 4, 15))

      expect(Pusher).to have_received(:trigger).at_least(:once)
      expect(Rails.cache).to have_received(:delete).at_least(:once)
    end

    # Documents a mismatch: affected_calendar_keys uses beginning_of_week
    # (Monday default) but CommunitiesController#calendar uses
    # beginning_of_week(:sunday). For dates near month boundaries, the
    # invalidation range can differ from the actual calendar range.
    it 'invalidates the previous month when a date falls in its Sunday-based calendar range' do
      # April 2026: calendar starts March 29 (Sunday). A meal on March 30
      # (Monday) is visible in the April calendar. The previous-month
      # invalidation should cover March.
      community.trigger_pusher(Date.new(2026, 3, 30))

      # March cache key should be deleted since March 30 is visible in
      # both the March and April calendar views.
      march_key = community.calendar_cache_key(2026, 3)
      expect(Rails.cache).to have_received(:delete).with(march_key)
    end

    # Pusher channels and cache keys use the same format, which must match
    # the frontend subscription in data_store.js: "community-{id}-calendar-{year}-{month}".
    # If these ever diverge (e.g., someone adds a version prefix to cache keys),
    # Pusher notifications would go to the wrong channel and real-time updates break silently.
    it 'uses the same key format for both Pusher channels and cache keys' do
      community.trigger_pusher(Date.new(2026, 4, 15))

      expected_format = /\Acommunity-\d+-calendar-\d+-\d+\z/

      pusher_channels = []
      expect(Pusher).to have_received(:trigger).at_least(:once) do |channel, _event, _data|
        pusher_channels << channel
      end
      expect(pusher_channels).to all match(expected_format)

      cache_keys = []
      expect(Rails.cache).to have_received(:delete).at_least(:once) do |key|
        cache_keys << key
      end
      expect(cache_keys).to all match(expected_format)

      expect(pusher_channels.sort).to eq(cache_keys.sort)
    end
  end
end
