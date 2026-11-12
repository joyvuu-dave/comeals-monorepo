# frozen_string_literal: true

require 'rails_helper'

# A race planted on purpose, to show what challenge 31 is for: a seed
# finds it, and the same seed finds it again, step for step.
#
# The race is the meal cap. A closed meal with a cap takes a signup while
# it holds fewer people than the cap (ClosedMealAttendanceFreeze counts
# them). Two signups for the last spot must not both count before either
# one saves. The meal lock (with_meal_lock) makes the second one wait,
# and SERIALIZABLE refuses one of them if the lock is ever left out. The
# plant takes both away: the write runs in a READ COMMITTED transaction
# with no lock. Then an order where both count first fills the meal past
# its cap. Whether real threads hit that order is chance; here the seed
# decides it.
#
# PostgreSQL refuses some COMMITs (a SERIALIZABLE conflict as the app is,
# which RetryOnConflict tries again), and each refusal sends "there is no
# transaction in progress" (request_storm_spec.rb says why).
RSpec.describe Simulation::Scheduler,
               prosopite: false, server_notices: [ServerNotices::REFUSED_COMMIT] do
  describe 'with a race planted in the meal cap' do
    include_context 'with no test transaction'
    include_context 'with a pool for a simulation', 6

    def seeds = (1..12)

    # One resident has signed up for a closed meal with a cap of 2, so one
    # spot is left. Two more residents each try to take it.
    def plant(seed)
      Simulation::World.plant(seed: seed, start: Simulation::Scheduler::START) do
        community = Community.create!(name: 'Simulation', timezone: 'America/Los_Angeles')
        unit = Unit.create!(name: 'Unit 0')
        residents = Array.new(3) do |i|
          Resident.create!(name: "Simulated #{i}", email: "simulated-#{i}@example.com", password: 'simulated',
                           unit: unit)
        end
        meal = Meal.create!(date: community.today + 3, rotation: Rotation.create!(no_email: true))
        MealResident.create!(meal: meal, resident: residents.first)
        meal.update!(closed: true, max: 2)
        { meal_id: meal.id, tokens: residents.drop(1).to_h { |r| [r.id, JwtAuth.encode(r)] } }
      end
    end

    def run(seed)
      Simulation::World.around_a_run do
        planted = plant(seed)
        scheduler = Simulation::Scheduler.new(seed: seed, start: Simulation::Scheduler::START + 60)
        planted[:tokens].each_with_index do |(resident_id, token), index|
          scheduler.actor(:"resident#{resident_id}") do
            Storm::RACK_TRANSPORT.call(:post, "/api/v1/meals/#{planted[:meal_id]}/residents/#{resident_id}",
                                       { 'Authorization' => "Bearer #{token}" },
                                       JSON.generate(late: false, vegetarian: false), "10.0.0.#{index + 1}").first
          end
        end
        result = scheduler.run
        { steps: result.steps, statuses: result.values, attendees: Meal.find(planted[:meal_id]).attendees_count }
      end
    end

    def plant_the_race
      # rubocop:disable-next RSpec/AnyInstance -- the plant replaces one private method of every controller instance
      allow_any_instance_of(Api::V1::MealsController).to receive(:with_meal_lock) do |_, before_settled_check:, &write|
        ActiveRecord::Base.transaction(isolation: :read_committed) { before_settled_check&.call || write.call }
      end
    end

    it 'never fills the meal past its cap as the app is' do
      runs = seeds.map { |seed| run(seed) }
      expect(runs.pluck(:attendees)).to all(eq(2))
      # Every seed gave one of them the spot and refused the other.
      expect(runs.map { |r| r[:statuses].values.sort }.uniq).to eq([[200, 400]])
    end

    it 'finds the planted race on some seed, and the same seed finds it again' do
      plant_the_race
      found = seeds.find { |seed| run(seed)[:attendees] > 2 }
      expect(found).not_to be_nil, "no seed in #{seeds} filled the meal past its cap"

      first, again = Array.new(2) { run(found) }
      expect(again).to eq(first)
      expect(again[:attendees]).to eq(3)
      expect(again[:statuses].values).to eq([200, 200])
    end

    it 'misses the planted race on seeds that run one signup before the other, every time' do
      plant_the_race
      missed = seeds.select { |seed| run(seed)[:attendees] == 2 }
      expect(missed).not_to be_empty
      expect(missed.map { |seed| run(seed)[:attendees] }).to all(eq(2))
    end
  end
end
