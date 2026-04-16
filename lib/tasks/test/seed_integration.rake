# frozen_string_literal: true

namespace :test do
  desc 'Seed test database with deterministic data for Playwright integration tests'
  task seed_integration: :environment do
    abort 'Must run in test environment' unless Rails.env.test?

    # Suppress Pusher during seeding (the initializer handles the server,
    # but the rake task runs outside the server process).
    Pusher.define_singleton_method(:trigger) { |*_args| true }

    # ------------------------------------------------------------------
    # CLEAN
    # ------------------------------------------------------------------
    # Truncate all tables in FK-safe order. CASCADE handles dependencies.
    ActiveRecord::Base.connection.execute('TRUNCATE communities CASCADE')
    Current.reset

    # ------------------------------------------------------------------
    # COMMUNITY
    # ------------------------------------------------------------------
    community = Community.create!(
      name: 'Test Community',
      slug: 'test-community',
      cap: nil,
      timezone: 'America/Los_Angeles'
    )

    AdminUser.create!(
      email: 'admin@test.com',
      password: 'password',
      password_confirmation: 'password',
      community: community
    )

    # ------------------------------------------------------------------
    # UNITS & RESIDENTS
    # ------------------------------------------------------------------
    unit_a = Unit.create!(name: 'A', community: community)
    unit_b = Unit.create!(name: 'B', community: community)
    unit_c = Unit.create!(name: 'C', community: community)

    jane = Resident.create!(
      name: 'Jane Smith', email: 'jane@test.com', password: 'password',
      community: community, unit: unit_a,
      multiplier: 2, can_cook: true, vegetarian: false,
      birthday: Date.new(1985, 3, 15)
    )

    bob = Resident.create!(
      name: 'Bob Johnson', email: 'bob@test.com', password: 'password',
      community: community, unit: unit_b,
      multiplier: 2, can_cook: true, vegetarian: true,
      birthday: Date.new(1990, 7, 22)
    )

    alice = Resident.create!(
      name: 'Alice Williams', email: 'alice@test.com', password: 'password',
      community: community, unit: unit_c,
      multiplier: 2, can_cook: false, vegetarian: false,
      birthday: Date.new(1978, 11, 8)
    )

    charlie = Resident.create!(
      name: 'Charlie Brown', password: '',
      community: community, unit: unit_a,
      multiplier: 1, can_cook: false, vegetarian: false,
      birthday: Date.new(2015, 5, 1)
    )

    Resident.create!(
      name: 'Diana Prince', email: 'diana@test.com', password: 'password',
      community: community, unit: unit_c,
      multiplier: 2, can_cook: true, vegetarian: false,
      active: false, birthday: Date.new(1982, 6, 20)
    )

    # ------------------------------------------------------------------
    # RECONCILED MEAL (60 days ago)
    # ------------------------------------------------------------------
    reconciled_meal = Meal.create!(
      date: 60.days.ago.to_date,
      community: community,
      description: 'Stir fry vegetables'
    )
    [jane, bob, alice, charlie].each do |r|
      MealResident.create!(
        resident: r, meal: reconciled_meal, community: community,
        multiplier: r.multiplier
      )
    end
    Bill.create!(
      meal: reconciled_meal, resident: alice,
      amount: BigDecimal('42.00'), community: community
    )

    # Creating the reconciliation triggers after_create :finalize, which
    # calls assign_meals (sweeps unreconciled meals with bills on or before
    # end_date) and persist_balances! (computes settlement).
    Reconciliation.create!(
      community: community,
      end_date: 30.days.ago.to_date
    )

    # ------------------------------------------------------------------
    # CLOSED MEAL (2 days ago)
    # ------------------------------------------------------------------
    closed_meal = Meal.create!(
      date: 2.days.ago.to_date,
      community: community,
      description: 'Tacos and rice',
      closed: true,
      max: 5
    )
    [bob, alice, charlie].each do |r|
      MealResident.create!(
        resident: r, meal: closed_meal, community: community,
        multiplier: r.multiplier
      )
    end
    Bill.create!(
      meal: closed_meal, resident: bob,
      amount: BigDecimal('35.50'), community: community
    )

    # ------------------------------------------------------------------
    # TODAY'S MEAL (open, no bills yet)
    # ------------------------------------------------------------------
    today_meal = Meal.create!(
      date: Date.current,
      community: community,
      description: 'Pizza and salad'
    )
    [jane, alice].each do |r|
      MealResident.create!(
        resident: r, meal: today_meal, community: community,
        multiplier: r.multiplier
      )
    end

    # ------------------------------------------------------------------
    # TOMORROW'S MEAL (open, with bill and guest)
    # ------------------------------------------------------------------
    tomorrow_meal = Meal.create!(
      date: Date.tomorrow,
      community: community,
      description: 'Pasta night with garlic bread'
    )
    [jane, bob, alice].each do |r|
      MealResident.create!(
        resident: r, meal: tomorrow_meal, community: community,
        multiplier: r.multiplier
      )
    end
    Guest.create!(
      meal: tomorrow_meal, resident: jane,
      multiplier: 2, vegetarian: true
    )
    Bill.create!(
      meal: tomorrow_meal, resident: jane,
      amount: BigDecimal('50.00'), community: community
    )

    # ------------------------------------------------------------------
    # FUTURE MEAL (7 days out, empty)
    # ------------------------------------------------------------------
    Meal.create!(
      date: 7.days.from_now.to_date,
      community: community
    )

    # ------------------------------------------------------------------
    # CALENDAR ITEMS
    # ------------------------------------------------------------------
    today = Date.current
    Event.create!(
      community: community, title: 'Community Meeting',
      start_date: Time.zone.local(today.year, today.month, today.day, 19, 0, 0),
      end_date: Time.zone.local(today.year, today.month, today.day, 21, 0, 0)
    )

    CommonHouseReservation.create!(
      community: community, resident: jane,
      title: 'Book Club',
      start_date: Time.zone.local(today.year, today.month, today.day, 10, 0, 0),
      end_date: Time.zone.local(today.year, today.month, today.day, 12, 0, 0)
    )

    GuestRoomReservation.create!(
      community: community, resident: bob,
      date: Date.tomorrow
    )

    # ------------------------------------------------------------------
    # OUTPUT
    # ------------------------------------------------------------------
    token = jane.key.token

    puts ''
    puts 'Integration seed complete:'
    puts "  Community:  #{community.name} (id: #{community.id})"
    puts "  Residents:  #{Resident.count} (#{Resident.where(active: true).count} active)"
    puts "  Meals:      #{Meal.count} (#{Meal.where.not(reconciliation_id: nil).count} reconciled)"
    puts "  Bills:      #{Bill.count}"
    puts "  Guests:     #{Guest.count}"
    puts ''
    puts "  Jane token: #{token}"
    puts "  Jane ID:    #{jane.id}"
    puts "  Community:  #{community.id}"

    # Write test context for Playwright to read at test time.
    auth_file = Rails.root.join('tmp/integration_auth.json')
    FileUtils.mkdir_p(auth_file.dirname)
    File.write(auth_file, JSON.pretty_generate(
                            token: token,
                            resident_id: jane.id,
                            community_id: community.id,
                            username: jane.name,
                            slug: community.slug,
                            bob_email: bob.email,
                            bob_password: 'password',
                            meals: {
                              reconciled: { id: reconciled_meal.id, date: reconciled_meal.date.iso8601 },
                              closed: { id: closed_meal.id, date: closed_meal.date.iso8601 },
                              today: { id: today_meal.id, date: today_meal.date.iso8601 },
                              tomorrow: { id: tomorrow_meal.id, date: tomorrow_meal.date.iso8601 }
                            }
                          ))
    puts "  Auth file:  #{auth_file}"
  end
end
