# frozen_string_literal: true

# == Schema Information
#
# Table name: communities
#
#  id                 :bigint           not null, primary key
#  cap                :decimal(12, 8)
#  dinner_start_times :jsonb            not null
#  free_below_age     :integer          default(5), not null
#  full_price_age     :integer          default(12), not null
#  meals_per_rotation :integer          default(12), not null
#  name               :string           not null
#  schedule           :jsonb            not null
#  singleton_guard    :integer          default(0), not null
#  timezone           :string           not null
#  created_at         :datetime         not null
#  updated_at         :datetime         not null
#
# Indexes
#
#  index_communities_on_name             (name) UNIQUE
#  index_communities_on_singleton_guard  (singleton_guard) UNIQUE
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

    it 'links the admins created before it, in the console during bootstrap' do
      orphan = create(:admin_user, community: nil)
      expect(orphan.community_id).to be_nil

      created = create(:community)

      expect(orphan.reload.community_id).to eq(created.id)
    end

    it 'prevents destruction' do
      expect(community.destroy).to be false
      expect(described_class.count).to eq(1)
    end

    # The refusal must run before the dependent: :destroy cascades. Inside
    # an outer transaction (a console session, a rake task) destroy joins
    # it, and when the refusal comes after the cascade, the swallowed
    # rollback leaves the children deleted (#26). An empty unit is a child
    # the cascade can delete.
    it 'refuses before deleting anything, inside an outer transaction' do
      empty_unit = create(:unit, community: community)

      described_class.transaction do
        expect(community.destroy).to be false
      end

      expect(Unit.exists?(empty_unit.id)).to be true
      expect(described_class.count).to eq(1)
    end
  end

  describe 'timezone' do
    # The DB column default was dropped (see 20260423170000 migration) so
    # operators must explicitly pick a tz at create time. This stops a
    # Berlin community from being set up on Pacific time with no error.
    it 'requires a timezone at creation' do
      community_without_tz = described_class.new(name: 'No TZ', timezone: nil)

      expect(community_without_tz).not_to be_valid
      expect(community_without_tz.errors[:timezone]).to be_present
    end

    it 'pushes the residents channel when the zone changes, and not for another change' do
      community
      RSpec::Mocks.space.proxy_for(Pusher).reset
      allow(Pusher).to receive(:trigger)
      residents_channel = "community-#{community.id}-residents"

      community.update!(timezone: 'Asia/Tokyo')
      expect(Pusher).to have_received(:trigger)
        .with(residents_channel, 'update', hash_including(message: 'residents updated')).once

      community.update!(name: 'Renamed')
      expect(Pusher).to have_received(:trigger).with(residents_channel, 'update', anything).once
    end

    it 'accepts any timezone from SUPPORTED_TIMEZONES' do
      Community::SUPPORTED_TIMEZONES.each_value do |iana|
        c = described_class.new(name: 'Fixture', timezone: iana)
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

  # An event or a common house booking may be set to end when it starts
  # only at midnight (#141). The community is in Los Angeles, and the days
  # are an ordinary one and both daylight saving days.
  describe '#midnight?' do
    let(:days) { [[2026, 4, 15], [2026, 3, 8], [2026, 11, 1]] }

    it 'is true at midnight in the community zone' do
      expect(days.map { |day| community.midnight?(Time.zone.local(*day)) }).to eq([true] * 3)
    end

    it 'is false a second before or after midnight, and at noon' do
      moments = days.flat_map do |day|
        midnight = Time.zone.local(*day)
        [midnight - 1.second, midnight + 1.second, Time.zone.local(*day, 12, 0)]
      end

      expect(moments.map { |moment| community.midnight?(moment) }).to eq([false] * 9)
    end

    # The same instants as a plain Time in UTC: midnight PDT is 07:00 UTC,
    # midnight PST is 08:00 UTC.
    it 'compares the instant, so a time in another zone or a plain Time gives the same answer' do
      moments = [Time.utc(2026, 4, 15, 7, 0), Time.utc(2026, 3, 8, 8, 0), Time.utc(2026, 11, 1, 7, 0),
                 Time.zone.local(2026, 3, 8).in_time_zone('Asia/Tokyo'), Time.utc(2026, 3, 8, 0, 0)]

      expect(moments.map { |moment| community.midnight?(moment) }).to eq([true, true, true, true, false])
    end

    # The app's own zone is Los Angeles. A task or a job has no zone of its
    # own, so the method must read the community's.
    it 'reads midnight in the community zone, not the app zone' do
      community.update!(timezone: 'America/New_York')
      new_york = ActiveSupport::TimeZone['America/New_York']

      expect(days.map { |day| community.midnight?(new_york.local(*day)) }).to eq([true] * 3)
      expect(days.map { |day| community.midnight?(Time.zone.local(*day)) }).to eq([false] * 3)
    end

    # In a zone ahead of UTC, midnight there is the evening before in UTC,
    # so the day must be read in the community zone, not in the zone the
    # time comes in. Berlin is UTC+1 in winter and UTC+2 in summer, and its
    # clocks change on 2026-03-29 and 2026-10-25, at 02:00 and 03:00, after
    # midnight.
    it 'reads the day in the community zone when that zone is ahead of UTC' do
      community.update!(timezone: 'Europe/Berlin')
      midnights = [Time.utc(2026, 4, 14, 22, 0), Time.utc(2026, 3, 28, 23, 0), Time.utc(2026, 10, 24, 22, 0)]

      expect(midnights.map { |moment| community.midnight?(moment) }).to eq([true] * 3)
      expect(community.midnight?(Time.utc(2026, 4, 15, 0, 0))).to be(false)
    end
  end

  # The two dashboard averages read the same meals: unreconciled, from a
  # day that is over, with at least one cook, someone who ate, and every
  # cook's cost entered. A cost is not entered while it is $0 and not
  # marked no-cost (cooksMissingCost in data_store.js says the same).
  # Before 2026-10-10 they counted tonight's meal and every past meal
  # without a cost at $0, so "Cost per adult" dropped every evening and
  # after every settlement.
  shared_context 'with meals for the dashboard averages' do
    include ActiveSupport::Testing::TimeHelpers

    let(:cook) { create(:resident, community: community, unit: unit, multiplier: 2) }
    let(:diner) { create(:resident, community: community, unit: unit, multiplier: 2) }

    # A meal with one bill, from its own cook, per amount (none: no cook),
    # and the given eaters.
    def meal_on(date, bills: [], eaters: [], no_cost: false)
      meal = create(:meal, community: community, date: date)
      bills.each do |amount|
        create(:bill, meal: meal, resident: create(:resident, community: community, unit: unit),
                      community: community, amount: BigDecimal(amount), no_cost: no_cost)
      end
      eaters.each { |eater| create(:meal_resident, meal: meal, resident: eater, community: community) }
      meal
    end
  end

  # The examples of the two averages read these meals through a number.
  # These read the list itself, one meal of each kind.
  describe '#averaged_meals' do
    include_context 'with meals for the dashboard averages'

    it 'is the past meals people ate at whose costs are final, and no other' do
      child = create(:resident, community: community, unit: unit, multiplier: 0)
      receipt = meal_on(community.today - 1, bills: %w[16], eaters: [cook, diner])
      no_cost = meal_on(community.today - 2, bills: %w[0], eaters: [diner], no_cost: true)
      meal_on(community.today - 3, eaters: [diner])
      meal_on(community.today - 4, bills: %w[20 0], eaters: [diner])
      meal_on(community.today - 5, bills: %w[0], eaters: [child])
      meal_on(community.today - 6, bills: %w[10], eaters: [child])
      meal_on(community.today - 7, bills: %w[25])
      meal_on(community.today - 9, bills: %w[0], no_cost: true)
      meal_on(community.today - 8, bills: %w[0], eaters: [diner], no_cost: true).cancel!
      meal_on(community.today, bills: %w[16], eaters: [diner])
      meal_on(community.today + 1, bills: %w[16], eaters: [diner])

      expect(community.averaged_meals).to contain_exactly(receipt, no_cost)
    end

    it 'leaves out a settled meal' do
      meal_on(community.today - 14, bills: %w[16], eaters: [cook, diner])
      settle!(cutoff: community.today - 14)
      open = meal_on(community.today - 2, bills: %w[6], eaters: [diner])

      expect(community.averaged_meals).to contain_exactly(open)
    end
  end

  describe '#averaged_meal_count' do
    include_context 'with meals for the dashboard averages'

    it 'counts the meals the averages read' do
      meal_on(community.today - 1, bills: %w[16], eaters: [cook, diner])
      meal_on(community.today - 2, bills: %w[0], eaters: [diner], no_cost: true)
      meal_on(community.today - 3, bills: %w[0], eaters: [diner])

      expect(community.averaged_meal_count).to eq(2)
    end
  end

  describe '#unreconciled_ave_cost' do
    include_context 'with meals for the dashboard averages'

    it 'returns average cost per adult for unreconciled meals' do
      meal_on(community.today - 1, bills: %w[16], eaters: [cook, diner])

      # total_multiplier = 2 + 2 = 4, total_cost = 16 (under the 4.50/unit cap),
      # cost_per_unit = 4, per_adult = 8
      expect(community.unreconciled_ave_cost).to eq('$8.00/adult')
    end

    # Settlement rule: a subsidized meal charges only its effective (capped)
    # cost — cap * multiplier — not the raw bill total.
    it 'uses the effective capped cost for subsidized meals' do
      meal_on(community.today - 1, bills: %w[40], eaters: [cook, diner])

      # cap 4.50 * multiplier 4 = 18 effective (raw 40); 2 * (18 / 4) = $9.00
      expect(community.unreconciled_ave_cost).to eq('$9.00/adult')
    end

    it 'returns -- when no unreconciled meals exist' do
      expect(community.unreconciled_ave_cost).to eq('--')
    end

    it 'leaves settled meals out' do
      meal_on(community.today - 14, bills: %w[16], eaters: [cook, diner])
      settle!(cutoff: community.today - 14)
      meal_on(community.today - 2, bills: %w[6], eaters: [diner])

      # Only the open meal: $6 over a multiplier of 2 is $3 a unit, $6 an adult.
      expect(community.unreconciled_ave_cost).to eq('$6.00/adult')
    end

    # A settlement holds back a meal with a receipt and nobody to
    # charge, so the averages leave it out too.
    it 'returns -- when only people who eat free ate' do
      child = create(:resident, community: community, unit: unit, multiplier: 0)
      meal_on(community.today - 1, bills: %w[10], eaters: [child])

      expect(community.unreconciled_ave_cost).to eq('--')
    end

    # Settlement rule: a bill on a meal nobody attended has zero financial
    # impact (the cook absorbs it). The dashboard average must skip it too.
    it 'excludes bills from meals with no attendees' do
      meal_on(community.today - 1, bills: %w[16], eaters: [cook, diner])
      meal_on(community.today - 2, bills: %w[60])

      # Only the attended meal counts: 2 * (16 / 4) = $8.00
      expect(community.unreconciled_ave_cost).to eq('$8.00/adult')
    end

    it 'excludes bills from meals only people who eat free ate, even uncapped' do
      child = create(:resident, community: community, unit: unit, multiplier: 0)
      meal_on(community.today - 1, bills: %w[16], eaters: [cook, diner])
      meal_on(community.today - 2, bills: %w[10], eaters: [child]).update!(cap: nil)

      # Only the attended meal contributes cost: 2 * (16 / 4) = $8.00
      expect(community.unreconciled_ave_cost).to eq('$8.00/adult')
    end

    # Tonight's cook often enters the receipt after dinner. At 5 pm the
    # cost is $0 and the sign-ups are in, so counting tonight pulled the
    # average down until the cook entered it. A settlement waits for
    # the day to be over, and so do the averages. If tonight counted,
    # the average would be $5.33.
    it "leaves out tonight's meal and tomorrow's" do
      meal_on(community.today - 1, bills: %w[16], eaters: [cook, diner])
      meal_on(community.today, bills: %w[0], eaters: [diner])
      meal_on(community.today + 1, bills: %w[30], eaters: [diner])

      expect(community.unreconciled_ave_cost).to eq('$8.00/adult')
    end

    # The meal is left out while any of its cooks has not entered a
    # cost, even when another cook has. Counted, these two would make
    # the average $6.25.
    it 'leaves out a past meal while a cook has not entered a cost' do
      meal_on(community.today - 1, bills: %w[16], eaters: [cook, diner])
      meal_on(community.today - 2, bills: %w[0], eaters: [diner])
      meal_on(community.today - 3, bills: %w[20 0], eaters: [diner])

      expect(community.unreconciled_ave_cost).to eq('$8.00/adult')
    end

    # A no-cost meal has a final cost of $0, so it counts.
    it 'counts a meal whose cook marked it no cost' do
      meal_on(community.today - 1, bills: %w[16], eaters: [cook, diner])
      meal_on(community.today - 2, bills: %w[0], eaters: [cook, diner], no_cost: true)

      # $16 over a multiplier of 8 is $2 a unit, $4 an adult.
      expect(community.unreconciled_ave_cost).to eq('$4.00/adult')
    end

    # 26 such meals were in production in 2026-09, from 2024-07-11 to
    # 2026-08-02. A settlement never claims a meal with no cook, so
    # right after each settlement they were most of what this average
    # read, and it showed about $0.00. Counted, this one would make the
    # average $5.33.
    it 'leaves out a past meal people ate at with no cook' do
      meal_on(community.today - 1, bills: %w[16], eaters: [cook, diner])
      meal_on(community.today - 2, eaters: [diner])

      expect(community.unreconciled_ave_cost).to eq('$8.00/adult')
    end

    # Every meal's sign-ups, guests and bills are read in one query each,
    # for all the meals at once, so three meals cost no more queries
    # than one.
    it 'reads three meals with as many queries as one' do
      meal_on(community.today - 1, bills: %w[16], eaters: [cook, diner])
      one = count_queries { community.unreconciled_ave_cost }
      meal_on(community.today - 2, bills: %w[8], eaters: [diner])
      meal_on(community.today - 3, bills: %w[8], eaters: [cook])

      expect(count_queries { community.unreconciled_ave_cost }).to eq(one)
    end

    it 'rounds a half cent the way BigDecimal and number_to_currency do' do
      meal_on(community.today - 1, bills: %w[16.25], eaters: [cook, diner])

      # 2 * (16.25 / 4) is exactly 8.125, under the 4.50/unit cap.
      expect(community.unreconciled_ave_cost).to eq('$8.13/adult')
    end

    # At 07:30 UTC on 2026-08-24 it is 00:30 in Los Angeles and still
    # 21:30 on 2026-08-23 in Honolulu. The Honolulu meal dated 08-23 is
    # tonight's, so it is left out. Read in another zone, it would
    # count and make the average $6.67.
    it "reads today in the community's time zone" do
      travel_to(Time.utc(2026, 8, 24, 7, 30)) do
        community.update!(timezone: 'Pacific/Honolulu')
        meal_on(Date.new(2026, 8, 22), bills: %w[16], eaters: [cook, diner])
        meal_on(Date.new(2026, 8, 23), bills: %w[4], eaters: [diner])

        expect(community.unreconciled_ave_cost).to eq('$8.00/adult')
      end
    end
  end

  describe '#unreconciled_ave_number_of_attendees' do
    include_context 'with meals for the dashboard averages'

    it 'returns average attendee count across unreconciled meals' do
      meal_on(community.today - 1, bills: %w[16], eaters: [cook, diner])
      meal_on(community.today - 2, bills: %w[16], eaters: [cook])

      # meal 1: 2 attendees, meal 2: 1 attendee, average = 1.5
      expect(community.unreconciled_ave_number_of_attendees).to eq(1.5)
    end

    it 'returns -- when no unreconciled meals exist' do
      expect(community.unreconciled_ave_number_of_attendees).to eq('--')
    end

    it 'leaves settled meals and their attendance out' do
      settled = meal_on(community.today - 14, bills: %w[16], eaters: [cook, diner])
      create(:guest, meal: settled, resident: diner)
      settle!(cutoff: community.today - 14)
      meal_on(community.today - 2, bills: %w[16], eaters: [diner])

      expect(community.unreconciled_ave_number_of_attendees).to eq(1.0)
    end

    it 'rounds to one decimal' do
      meal_on(community.today - 1, bills: %w[16], eaters: [cook, diner])
      meal_on(community.today - 2, bills: %w[16], eaters: [cook])
      meal_on(community.today - 3, bills: %w[16], eaters: [cook])

      # 4 attendees over 3 meals is 1.333..., shown as 1.3. A Float, so
      # the dashboard prints 1.3: a Rational would print as 13/10.
      expect(community.unreconciled_ave_number_of_attendees).to be(1.3)
    end

    it 'counts guests in addition to residents' do
      meal = meal_on(community.today - 1, bills: %w[16], eaters: [cook])
      create(:guest, meal: meal, resident: cook)

      # 1 resident + 1 guest = 2 attendees / 1 meal = 2.0
      expect(community.unreconciled_ave_number_of_attendees).to eq(2.0)
    end

    # The same meals as the cost. Each one left out here has one
    # attendee, so counting any of them would bring the average below 2.
    it 'reads the same meals as the cost' do
      child = create(:resident, community: community, unit: unit, multiplier: 0)
      meal_on(community.today - 1, bills: %w[16], eaters: [cook, diner])
      meal_on(community.today - 2, eaters: [diner])
      meal_on(community.today - 3, bills: %w[0], eaters: [diner])
      meal_on(community.today - 4, bills: %w[10], eaters: [child])
      meal_on(community.today - 5, bills: %w[0], no_cost: true)
      meal_on(community.today, bills: %w[16], eaters: [diner])
      meal_on(community.today + 7, eaters: [diner])

      expect(community.unreconciled_ave_number_of_attendees).to eq(2.0)
    end

    it "reads today in the community's time zone" do
      travel_to(Time.utc(2026, 8, 24, 7, 30)) do
        community.update!(timezone: 'Pacific/Honolulu')
        meal_on(Date.new(2026, 8, 22), bills: %w[16], eaters: [cook])
        meal_on(Date.new(2026, 8, 23), bills: %w[16], eaters: [cook, diner])

        expect(community.unreconciled_ave_number_of_attendees).to eq(1.0)
      end
    end
  end

  # Every past meal people ate at that is not settled yet is either
  # counted or left out, for one reason only, so the dashboard's
  # numbers add up to the meals people ate at.
  describe '#meals_left_out_of_averages' do
    include_context 'with meals for the dashboard averages'

    it 'counts each past meal people ate at once, as counted or left out for its first reason' do
      child = create(:resident, community: community, unit: unit, multiplier: 0)
      # Counted: a receipt, and a no-cost meal.
      meal_on(community.today - 1, bills: %w[16], eaters: [cook, diner])
      meal_on(community.today - 2, bills: %w[0], eaters: [diner], no_cost: true)
      # No cook.
      meal_on(community.today - 3, eaters: [diner])
      # A cost not entered, on one cook or on one of two, and one that
      # only a free eater ate as well.
      meal_on(community.today - 4, bills: %w[0], eaters: [diner])
      meal_on(community.today - 5, bills: %w[20 0], eaters: [diner])
      meal_on(community.today - 6, bills: %w[10 0], eaters: [child])
      # Nobody to charge: only a free eater ate, at two meals, so this
      # count is not the one meal above that also waits for a cost.
      meal_on(community.today - 7, bills: %w[10], eaters: [child])
      meal_on(community.today - 12, bills: %w[5], eaters: [child])
      # Neither: nobody ate, tonight, tomorrow.
      meal_on(community.today - 8, bills: %w[25])
      meal_on(community.today - 9)
      meal_on(community.today, eaters: [diner])
      meal_on(community.today + 1, bills: %w[0], eaters: [diner])
      # Cancelled (ADR 0011 rule 11): one with no cook and one with a
      # blank cost, each counted once, as cancelled only.
      meal_on(community.today - 10, eaters: [diner]).cancel!
      meal_on(community.today - 11, bills: %w[0], eaters: [diner]).cancel!

      expect(community.averaged_meal_count).to eq(2)
      expect(community.meals_left_out_of_averages)
        .to eq(cancelled: 2, no_cook: 1, cost_not_entered: 3, nobody_to_charge: 2)
    end

    # A cancelled dinner and a dinner where only a child who eats free
    # ate both settle, the second with its cost still blank. Once
    # settled, neither is waiting for anything.
    it 'leaves settled meals out of every count' do
      child = create(:resident, community: community, unit: unit, multiplier: 0)
      meal_on(community.today - 15, bills: %w[0], eaters: [diner]).cancel!
      meal_on(community.today - 16, bills: %w[0], eaters: [child])
      settle!(cutoff: community.today - 14)

      expect(community.meals_left_out_of_averages)
        .to eq(cancelled: 0, no_cook: 0, cost_not_entered: 0, nobody_to_charge: 0)
    end

    it 'counts nothing and leaves nothing out when no meal is past' do
      meal_on(community.today, bills: %w[0], eaters: [diner])

      expect(community.averaged_meal_count).to eq(0)
      expect(community.meals_left_out_of_averages)
        .to eq(cancelled: 0, no_cook: 0, cost_not_entered: 0, nobody_to_charge: 0)
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

    # A cap is typed by a person, so it is whole cents — the same rule
    # Bill#amount enforces. 2.32481286 can only be a typo.
    it 'refuses a cap with a third decimal, the smallest fraction of a cent' do
      community.cap = BigDecimal('2.125')
      expect(community).not_to be_valid
      expect(community.errors[:cap]).to include('must be whole cents')
    end

    it 'refuses a sub-cent cap' do
      community.cap = BigDecimal('2.32481286')
      expect(community).not_to be_valid
      expect(community.errors[:cap]).to include('must be whole cents')
    end

    it 'the database refuses a sub-cent cap from writes that skip the model' do
      community # the lazy let — without a row, update_all updates nothing

      expect { described_class.update_all(cap: BigDecimal('2.32481286')) }
        .to raise_error(ActiveRecord::StatementInvalid, /communities_cap_whole_cents/)
    end
  end

  describe 'child pricing ages' do
    it 'reports a missing age without comparing it to the other one' do
      community.free_below_age = nil
      expect(community).not_to be_valid
      expect(community.errors[:free_below_age]).to include('must be a whole number of years, 0 or more')
      expect(community.errors[:free_below_age]).not_to include(/at or below/)

      community.free_below_age = 5
      community.full_price_age = nil
      expect(community).not_to be_valid
      expect(community.errors[:full_price_age]).to include('must be a whole number of years, 0 or more')
      expect(community.errors[:free_below_age]).to be_empty
    end

    it 'defaults to eating free below 5 and full price from 12' do
      expect(community.free_below_age).to eq(5)
      expect(community.full_price_age).to eq(12)
    end

    it 'allows equal ages, which means no half-price band' do
      community.assign_attributes(free_below_age: 7, full_price_age: 7)
      expect(community).to be_valid
    end

    it 'allows both ages 0, which means everyone pays full price' do
      community.assign_attributes(free_below_age: 0, full_price_age: 0)
      expect(community).to be_valid
    end

    it 'refuses a negative age' do
      community.free_below_age = -1
      expect(community).not_to be_valid
      expect(community.errors[:free_below_age]).to include('must be a whole number of years, 0 or more')
    end

    it 'refuses a fractional age' do
      community.full_price_age = 11.5
      expect(community).not_to be_valid
      expect(community.errors[:full_price_age]).to include('must be a whole number of years, 0 or more')
    end

    it 'refuses a free-below age above the full-price age' do
      community.assign_attributes(free_below_age: 13, full_price_age: 12)
      expect(community).not_to be_valid
      expect(community.errors[:free_below_age])
        .to include('must be at or below the full-price age — a child eats free before they pay half price')
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

      community.schedule = [[0, -1]]
      expect(community).not_to be_valid
      expect(community.errors[:schedule]).to include('days must be 0 (Sunday) through 6 (Saturday)')
    end

    it 'refuses a bad week even when the other weeks are fine' do
      community.schedule = [[0, 4], [7]]
      expect(community).not_to be_valid
      expect(community.errors[:schedule]).to include('days must be 0 (Sunday) through 6 (Saturday)')
    end

    it 'drops a field that holds only spaces, like an empty one' do
      community.schedule = { '0' => [' ', '4', ' 0'] }
      expect(community.schedule).to eq([[0, 4]])
      expect(community).to be_valid
    end

    it 'reports rather than raises on uncoercible form input' do
      community.schedule = { '0' => %w[banana 0] }
      expect(community.schedule).to eq([[nil, 0]])
      expect(community).not_to be_valid
      expect(community.errors[:schedule]).to include('days must be 0 (Sunday) through 6 (Saturday)')
    end

    it 'reads a day as it is written, so 2.5 is refused and not cut down to Tuesday' do
      community.schedule = [[2.5]]
      expect(community.schedule).to eq([[nil]])
      expect(community).not_to be_valid
      expect(community.errors[:schedule]).to eq(['days must be 0 (Sunday) through 6 (Saturday)'])
    end

    it 'keeps a value that is not a list of weeks for the validation to report' do
      community.schedule = nil
      expect(community).not_to be_valid
      expect(community.errors[:schedule]).to include('must have between 1 and 6 weeks')

      # Six letters, so the length alone does not refuse it.
      community.schedule = 'Monday'
      expect(community.schedule).to eq('Monday')
      expect(community).not_to be_valid
      expect(community.errors[:schedule]).to eq(['must have between 1 and 6 weeks'])

      community.schedule = { '0' => 'Monday' }
      expect(community.schedule).to eq(['Monday'])
      expect(community).not_to be_valid
      expect(community.errors[:schedule]).to include('days must be 0 (Sunday) through 6 (Saturday)')
    end

    # The writer turns every day into a whole number or nil, so these
    # shapes can only come from a write that skips it (the console, psql).
    # The validation still has to report them when the record is saved.
    it 'refuses a day stored as a decimal' do
      community[:schedule] = [[3.0]]
      expect(community).not_to be_valid
      expect(community.errors[:schedule]).to eq(['days must be 0 (Sunday) through 6 (Saturday)'])
    end

    it 'reports a list inside a week once, not also as a schedule with no meal day' do
      community[:schedule] = [[[]]]
      expect(community).not_to be_valid
      expect(community.errors[:schedule]).to eq(['days must be 0 (Sunday) through 6 (Saturday)'])
    end

    it 'refuses a meals_per_rotation outside 1 to 100' do
      [0, -3, 101, 2.5].each do |bad|
        community.meals_per_rotation = bad
        expect(community).not_to be_valid
        expect(community.errors[:meals_per_rotation]).to include('must be a whole number from 1 to 100')
      end
    end

    it 'saves without raising instead of hitting the database constraint' do
      expect { community.update(schedule: [[], []]) }.not_to raise_error
      expect(community.reload.schedule).to eq([[0, 1, 4], [0, 2, 4]])
    end

    it '#meal_schedule wraps the schedule column' do
      schedule = community.meal_schedule
      expect(schedule).to be_a(MealSchedule)
      expect(schedule.weeks).to eq(community.schedule)
    end
  end

  describe '#create_next_rotation' do
    it 'creates a rotation with meals_per_rotation meals' do
      community.create_next_rotation

      expect(community.rotations.count).to eq(1)
      expect(community.meals.count).to eq(community.meals_per_rotation)
    end

    it 'creates meals only on days the schedule allows' do
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
    # same starting state (computed from it before it was deleted). The row
    # arrangement matches what migration 20260808120000 produces when it
    # rotates a schedule into epoch phase, so this pins "the first rotation
    # generated after deploy matches what the old code would have created" —
    # including which of the alternating days comes next. The week of Sunday
    # 2026-08-02 is a week-2 week under MealSchedule::EPOCH, so the row that
    # holds that week's alternating day is the second row.
    describe 'equivalence with the old algorithm' do
      include ActiveSupport::Testing::TimeHelpers

      let(:rotation) { create(:rotation, community: community) }

      it 'continues the alternation when the last alternating meal was a Monday' do
        travel_to Date.new(2026, 8, 7) do
          create(:meal, community: community, date: Date.new(2026, 8, 3), rotation_id: rotation.id)
          # The last alternating meal, Monday 2026-08-03, is in the week of
          # 2026-08-02 — a week-2 week — so Monday goes in the second row.
          community.update!(schedule: [[0, 2, 4], [0, 1, 4]])

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
          # The last alternating meal, Tuesday 2026-08-04, is in the week of
          # 2026-08-02 — a week-2 week — so Tuesday goes in the second row.
          community.update!(schedule: [[0, 1, 4], [0, 2, 4]])

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
          community.create_next_rotation
          community.create_next_rotation

          # Mondays and Tuesdays must strictly alternate across the rotation
          # boundary — the old code got this from meal history, the new code
          # from epoch arithmetic.
          alternating = community.meals.order(:date).pluck(:date).map(&:wday).select { |d| [1, 2].include?(d) }
          alternating.each_cons(2) { |a, b| expect(a).not_to eq(b) }
        end
      end
    end

    it 'starts after the latest meal date, not after the meal entered last' do
      rotation = create(:rotation, community: community, no_email: true)
      create(:meal, community: community, rotation: rotation, date: community.today + 30)
      create(:meal, community: community, rotation: rotation, date: community.today + 10)

      community.create_next_rotation

      expect(community.rotations.order(:id).last.meals.minimum(:date)).to be > community.today + 30
    end
  end

  # Which months a changed day reaches, seen through LiveUpdate.calendar,
  # which clears and pushes exactly the keys this method returns.
  describe '#affected_calendar_keys' do
    before do
      community
      allow(Rails.cache).to receive(:delete)
    end

    # Every key the day reached, and every channel it pushed to. The block
    # goes to `to` (do...end), which hands it each call's arguments.
    def cleared_keys
      keys = []
      expect(Rails.cache).to have_received(:delete).at_least(:once) do |key|
        keys << key
      end
      keys
    end

    def pushed_channels
      channels = []
      expect(Pusher).to have_received(:trigger).at_least(:once) do |channel, _event, _data|
        channels << channel
      end
      channels
    end

    it 'clears and pushes the month the day is in, and only that month' do
      LiveUpdate.calendar(Date.new(2026, 4, 15))

      april = community.calendar_cache_key(2026, 4)
      expect(cleared_keys).to eq([april])
      expect(pushed_channels).to eq([april])
    end

    # March 2026 starts on a Sunday, so its six weeks run March 1 to
    # April 11. April 5 is on March's calendar and on April's own.
    it 'invalidates the previous month when the day is on its six weeks' do
      LiveUpdate.calendar(Date.new(2026, 4, 5))

      march = community.calendar_cache_key(2026, 3)
      april = community.calendar_cache_key(2026, 4)
      expect(cleared_keys).to contain_exactly(march, april)
      expect(pushed_channels).to contain_exactly(march, april)
    end

    # May 2026 starts on a Friday, so the May calendar starts on Sunday
    # April 26 and shows April 26-30. A change on April 26 must reach the
    # May month. The old check asked whether the date's week ended in the
    # next month, and with Monday-start weeks a Sunday's week ends on
    # itself — so a Sunday at the end of a month never cleared or pushed
    # the next month, and the May calendar showed a stale April 26.
    it 'invalidates the next month when a Sunday falls in its calendar range' do
      LiveUpdate.calendar(Date.new(2026, 4, 26))

      may_key = community.calendar_cache_key(2026, 5)
      expect(Rails.cache).to have_received(:delete).with(may_key)
      expect(Pusher).to have_received(:trigger).with(may_key, 'update', anything)
    end

    # A date that no other month shows must clear only its own month.
    # Over-clearing is only cost, but a spec that checked only inclusion
    # would pass a "clear everything" version too.
    it 'does not invalidate a neighbouring month that does not show the date' do
      LiveUpdate.calendar(Date.new(2026, 4, 15))

      expect(Rails.cache).to have_received(:delete).with(community.calendar_cache_key(2026, 4))
      expect(Rails.cache).not_to have_received(:delete).with(community.calendar_cache_key(2026, 3))
      expect(Rails.cache).not_to have_received(:delete).with(community.calendar_cache_key(2026, 5))
    end

    # Pusher channels and cache keys use the same format, which must match
    # the frontend subscription in data_store.js: "community-{id}-calendar-{year}-{month}".
    # If these ever diverge (e.g., someone adds a version prefix to cache keys),
    # Pusher notifications would go to the wrong channel, and real-time updates would stop with no error.
    it 'uses the same key format for both Pusher channels and cache keys' do
      LiveUpdate.calendar(Date.new(2026, 4, 15))

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
