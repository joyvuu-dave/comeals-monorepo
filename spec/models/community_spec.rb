# frozen_string_literal: true

# == Schema Information
#
# Table name: communities
#
#  id              :bigint           not null, primary key
#  cap             :decimal(12, 8)
#  name            :string           not null
#  singleton_guard :integer          default(0), not null
#  slug            :string           not null
#  timezone        :string           not null
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
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
      create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('40'))
      create(:meal_resident, meal: meal, resident: cook, community: community)
      create(:meal_resident, meal: meal, resident: diner, community: community)

      result = community.unreconciled_ave_cost
      # total_multiplier = 2 + 2 = 4, total_cost = 40, cost_per_unit = 10, per_adult = 20
      expect(result).to eq('$20.00/adult')
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

    it 'creates meals only on valid days (Sun, Mon/Tue alternating, Fri)' do
      4.times { create(:resident, community: community, unit: unit, multiplier: 2, can_cook: true) }

      community.create_next_rotation

      wdays = community.meals.pluck(:date).map(&:wday)
      expect(wdays.all? { |d| [0, 1, 2, 4].include?(d) }).to be true
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
      expect(rotation.description).to eq("#{first_meal_date} to #{last_meal_date}")
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
