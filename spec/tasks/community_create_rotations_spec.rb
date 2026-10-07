# frozen_string_literal: true

require 'rails_helper'
require 'rake'

RSpec.describe 'community:create_rotations' do
  include ActiveSupport::Testing::TimeHelpers

  before(:all) do
    RakeTasks.ensure_loaded
  end

  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }

  after do
    Rake::Task['community:create_rotations'].reenable
  end

  # The loop stops at the first rotation that reaches the horizon. So the
  # newest rotation has a meal on or after it, and every earlier rotation
  # ends before it: a longer horizon, or one rotation too many, would put
  # an earlier rotation's meals past it too.
  it 'creates rotations until meals exist 6 months out, and stops there' do
    travel_to(Time.zone.local(2026, 1, 15, 12)) do
      # Community needs at least one resident for meal scheduling context
      create(:resident, community: community, unit: unit)

      expect(community.meals.count).to eq(0)

      Rake::Task['community:create_rotations'].invoke

      horizon = community.today + 6.months
      newest = community.rotations.order(:id).last
      expect(community.rotations.count).to be > 1
      expect(newest.meals.maximum(:date)).to be >= horizon
      expect(community.meals.where.not(rotation: newest).maximum(:date)).to be < horizon
    end
  end

  # Exactly on the horizon is far enough: the job looks for a meal on or
  # after today + 6 months.
  it 'does not create rotations when a meal is already exactly 6 months out' do
    rotation = create(:rotation, community: community)
    create(:meal, community: community, rotation: rotation,
                  date: community.today + 6.months)

    initial_rotation_count = community.rotations.count

    Rake::Task['community:create_rotations'].invoke

    expect(community.rotations.count).to eq(initial_rotation_count)
  end

  it 'creates meals that skip holidays' do
    # Pin "today" to a date that puts both holidays comfortably inside the
    # 6-month window with adjacent meal-day Sundays still in the future.
    # Without this, the test breaks once the calendar passes the last April
    # Sunday (and again in any year where Easter falls on a different date).
    travel_to(Date.new(2026, 1, 15)) do
      create(:resident, community: community, unit: unit)

      Rake::Task['community:create_rotations'].invoke

      meal_dates = community.meals.pluck(:date)
      # Easter 2026 is April 5 (Sunday) and Mother's Day 2026 is May 10 (Sunday).
      # Both are permanent meal days (Sunday = day 0) and within the 6-month window.
      # If the holiday check is removed, meals WOULD be created on these dates.
      easter = Date.new(2026, 4, 5)
      mothers_day = Date.new(2026, 5, 10)
      expect(meal_dates).not_to include(easter)
      expect(meal_dates).not_to include(mothers_day)
      # Verify meals exist on adjacent Sundays so the check isn't vacuous
      expect(meal_dates.any? { |d| d.sunday? && d.month == 4 }).to be true
      expect(meal_dates.any? { |d| d.sunday? && d.month == 5 }).to be true
    end
  end
end
