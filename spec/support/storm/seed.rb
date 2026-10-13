# frozen_string_literal: true

# The rows a request storm runs against: one community, a few units, one
# resident per client, and a row of meals. Some meals are at least 14 days
# in the past, so a settlement can claim them while the storm runs
# (Reconciliation::DAYS_TO_WAIT); some are in the future, so writes keep
# going after the past ones are settled.
#
# Plain models, not factories: the real-server storm (rake test:storm)
# plants the same rows from a rake task, where FactoryBot is not loaded.
module Storm
  class Seed
    # admin_rows: the ids of the attendance rows the storm's admin added
    # (Run#admin_write). An admin correction may put a closed meal over its
    # max, so Checks#check_cap leaves those rows out of the count.
    #
    # baseline_meal: a future meal that only Storm::Baseline writes to. No
    # client, settler or admin picks it, so the baseline finds it the same
    # after the storm as before.
    #
    # settleable_meal: the past meal planted so a settlement always has
    # something to claim (make_settleable). No client or admin leaves a
    # cost blank on it, because a blank cost makes a meal with someone to
    # charge wait (ADR 0011 rule 3).
    Plan = Struct.new(:community, :residents, :tokens, :meals, :admin_rows, :baseline_meal, :settleable_meal,
                      keyword_init: true) do
      def reconcilers
        residents.select(&:can_reconcile?)
      end

      def meal_ids
        meals.map(&:id)
      end

      # The latest cutoff a settlement may have today, 14 days back (ADR
      # 0011 rule 2). The settler, the previews and the settle requests
      # all use it.
      def latest_cutoff
        Reconciliation.latest_cutoff(community.today)
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
      # Every meal belongs to a rotation (NOT NULL on meals.rotation_id).
      rotation = Rotation.create!(no_email: true)
      today = community.today
      latest = Reconciliation.latest_cutoff(today)
      dates = (0...PAST_MEALS).map { |n| latest - n } + (1..FUTURE_MEALS).map { |n| today + n }
      meals = dates.map { |date| Meal.create!(date: date, rotation: rotation) }
      make_settleable(meals.first, residents.first)
      Plan.new(community: community, residents: residents,
               tokens: residents.to_h { |r| [r.id, JwtAuth.encode(r)] }, meals: meals,
               admin_rows: Concurrent::Set.new,
               baseline_meal: Meal.create!(date: today + FUTURE_MEALS + 1, rotation: rotation),
               settleable_meal: meals.first)
    end

    private

    # A settlement claims only a meal with a cook and, when the cook spent
    # money, someone who pays to eat it (Meal.settleable_by). Until
    # 2026-10 the storm planted neither, so the settler had something to
    # claim only after a client's bills save went through on a past meal.
    # On a busy machine most bills saves end in 409. One run had 1 of 34
    # go through, the settler found nothing to settle, and the spec failed
    # with every other check passing (#131).
    #
    # So the newest past meal starts with a cook who spent $40 and a guest
    # of theirs. Nothing in the storm can take both away: a client removes
    # only the guests it added itself, the admin writes attendance and
    # bills but never deletes a bill, and a bills save always leaves at
    # least one cook. Nothing leaves a cost blank on it either (Plan). The
    # storm's writes still race the settlement on this meal as on any
    # other.
    def make_settleable(meal, cook)
      Bill.create!(meal: meal, resident: cook, amount: BigDecimal('40'), no_cost: false)
      Guest.create!(meal: meal, resident: cook, multiplier: 2, vegetarian: false, late: false)
    end

    def resident(index, unit)
      multiplier = MULTIPLIERS[index % MULTIPLIERS.size]
      birthday = { 0 => 3.years.ago.to_date, 1 => 8.years.ago.to_date }[multiplier]
      Resident.create!(name: "Storm Client #{index}", email: "storm-#{index}@example.com", password: 'storm',
                       unit: unit, birthday: birthday,
                       can_reconcile: (index % 4).zero?)
    end
  end
end
