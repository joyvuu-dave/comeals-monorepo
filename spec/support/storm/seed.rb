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
    # settleable_meals: the past meals planted so a settlement always has
    # something to claim (make_settleable). No client or admin leaves a
    # cost blank on one, because a blank cost makes a meal with someone to
    # charge wait (ADR 0011 rule 3). The storm plants one. The fault suite
    # plants more, one a day, so that settlements go on all through a run
    # and a settle request can succeed (challenge 30).
    #
    # settle_cutoffs: with more than one, the dates of those meals, oldest
    # first, and settle_step the index of the one the fault suite's settle
    # phone settles next (Faults::Session#settle_phone). Each press settles
    # up to that date, so it claims about one meal and leaves the rest for
    # the next. With one meal there is no list, and every settlement takes
    # the latest cutoff.
    Plan = Struct.new(:community, :residents, :tokens, :meals, :admin_rows, :baseline_meal, :settleable_meals,
                      :settle_cutoffs, :settle_step, keyword_init: true) do
      def reconcilers
        residents.select(&:can_reconcile?)
      end

      def meal_ids
        meals.map(&:id)
      end

      def settleable?(meal)
        settleable_meals.any? { it.id == meal.id }
      end

      # The latest cutoff a settlement may have today, 14 days back (ADR
      # 0011 rule 2). The previews use it.
      def latest_cutoff
        Reconciliation.latest_cutoff(community.today)
      end

      # The cutoff the storm's settler and settle requests ask for. With a
      # list, the dates take turns. On an even step they ask for the settle
      # phone's own next date, and race it and each other for that meal.
      # On an odd step they ask for the date before it, so the phone
      # settles that meal alone. The settler runs every 0.3 seconds, so
      # with the phone's date on every step it took every meal first, and
      # a 30-second run had no settle phone success.
      def settle_cutoff
        return latest_cutoff unless settle_cutoffs

        step = [settle_step.value, settle_cutoffs.size - 1].min
        return phone_cutoff if step.even?

        settle_cutoffs.fetch(step - 1)
      end

      # The settle phone's next cutoff, and the step past it once that
      # press was answered with anything but a conflict or the database
      # out of reach. The last date stays the last.
      def phone_cutoff
        settle_cutoffs.fetch([settle_step.value, settle_cutoffs.size - 1].min)
      end

      def phone_settled
        settle_step.increment
      end
    end

    PAST_MEALS = 6
    FUTURE_MEALS = 4

    # Mostly adults, some children at half price and some free, like the
    # community. A child (1 or 0) must carry a birthday (Resident).
    MULTIPLIERS = [2, 2, 2, 1, 0].freeze

    def self.plant(clients:, settleable: 1)
      new(clients, settleable).plant
    end

    def initialize(clients, settleable)
      @clients = clients
      @settleable = settleable
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
      past = [PAST_MEALS, @settleable].max
      dates = (0...past).map { |n| latest - n } + (1..FUTURE_MEALS).map { |n| today + n }
      meals = dates.map { |date| Meal.create!(date: date, rotation: rotation) }
      settleable = meals.first(@settleable)
      settleable.each_with_index { |meal, i| make_settleable(meal, residents[i % residents.size]) }
      Plan.new(community: community, residents: residents,
               tokens: residents.to_h { |r| [r.id, JwtAuth.encode(r)] }, meals: meals,
               admin_rows: Concurrent::Set.new,
               baseline_meal: Meal.create!(date: today + FUTURE_MEALS + 1, rotation: rotation),
               settleable_meals: settleable, **cutoffs(settleable))
    end

    private

    def cutoffs(settleable)
      return {} if settleable.size < 2

      { settle_cutoffs: settleable.map(&:date).sort, settle_step: Concurrent::AtomicFixnum.new(0) }
    end

    # A settlement claims only a meal with a cook and, when the cook spent
    # money, someone who pays to eat it (Meal.settleable_by). Until
    # 2026-10 the storm planted neither, so the settler had something to
    # claim only after a client's bills save went through on a past meal.
    # On a busy machine most bills saves end in 409. One run had 1 of 34
    # go through, the settler found nothing to settle, and the spec failed
    # with every other check passing (#131).
    #
    # So each of these meals starts with a cook who spent $40 and a guest
    # of theirs. Nothing in the storm can take both away: a client removes
    # only the guests it added itself, the admin writes attendance and
    # bills but never deletes a bill, and a bills save always leaves at
    # least one cook. Nothing leaves a cost blank on it either (Plan). The
    # storm's writes still race the settlement on these meals as on any
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
