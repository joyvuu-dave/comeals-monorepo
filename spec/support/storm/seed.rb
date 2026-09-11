# frozen_string_literal: true

# The rows a request storm runs against: one community, a few units, one
# resident per client, and a row of meals. Some meals are in the past, so
# a settlement can claim them while the storm runs; some are in the
# future, so writes keep going after the past ones are settled.
#
# Plain models, not factories: the real-server storm (rake test:storm)
# plants the same rows from a rake task, where FactoryBot is not loaded.
module Storm
  class Seed
    Plan = Struct.new(:community, :residents, :tokens, :meals, keyword_init: true) do
      def reconcilers
        residents.select(&:can_reconcile?)
      end

      def meal_ids
        meals.map(&:id)
      end
    end

    PAST_MEALS = 6
    FUTURE_MEALS = 4

    # Mostly adults, some children at half price and some free, like the
    # community. A child (1 or 0) must carry a birthday (Resident).
    MULTIPLIERS = [2, 2, 2, 1, 0].freeze

    def self.plant(clients:)
      new(clients).plant
    end

    def initialize(clients)
      @clients = clients
    end

    def plant
      community = Community.first || Community.create!(name: 'Storm Community', timezone: 'America/Los_Angeles')
      Current.reset
      units = Array.new(4) { |i| Unit.create!(name: "Storm Unit #{i}") }
      residents = Array.new(@clients) { |i| resident(i, units[i % units.size]) }
      # EnsureRotationsJob refuses to run while a meal has no rotation.
      rotation = Rotation.create!(no_email: true)
      today = community.today
      dates = (1..PAST_MEALS).map { |n| today - n } + (1..FUTURE_MEALS).map { |n| today + n }
      meals = dates.map { |date| Meal.create!(date: date, rotation: rotation) }
      Plan.new(community: community, residents: residents,
               tokens: residents.to_h { |r| [r.id, JwtAuth.encode(r)] }, meals: meals)
    end

    private

    def resident(index, unit)
      multiplier = MULTIPLIERS[index % MULTIPLIERS.size]
      birthday = { 0 => 3.years.ago.to_date, 1 => 8.years.ago.to_date }[multiplier]
      Resident.create!(name: "Storm Client #{index}", email: "storm-#{index}@example.com", password: 'storm',
                       unit: unit, multiplier: multiplier, birthday: birthday,
                       can_reconcile: (index % 4).zero?)
    end
  end
end
