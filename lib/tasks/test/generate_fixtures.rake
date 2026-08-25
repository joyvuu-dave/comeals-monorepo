# frozen_string_literal: true

namespace :test do
  desc 'Generate tests/fixtures/*.json from the real API (deploy-confidence-plan item 7)'
  # The mocked E2E suite serves these files instead of running Rails. They
  # used to be written by hand, and they drifted: the handwritten calendar
  # gave tiles titles like "CH: Book Club" while the real serializers emit
  # multiline titles. Generating them through the real controller stack —
  # an integration session against seeded records — makes the fixtures the
  # same JSON production serves, by construction. bin/check regenerates
  # them and fails when the result differs from what is committed, so a
  # serializer change always travels with its fixture change.
  #
  # Everything is pinned so two runs write identical bytes: record ids,
  # every created_at (via travel_to), and the clock the requests run under
  # (2026-01-15 noon, the same frozen "today" the E2E specs use).
  task generate_fixtures: :environment do
    abort 'Must run in test environment' unless Rails.env.test?

    require 'active_support/testing/time_helpers'
    clock = Object.new.extend(ActiveSupport::Testing::TimeHelpers)

    # The rake task runs outside the server process, so stub Pusher here.
    Pusher.define_singleton_method(:trigger) { |*_args| true }

    # ------------------------------------------------------------------
    # CLEAN
    # ------------------------------------------------------------------
    ActiveRecord::Base.connection.execute('TRUNCATE communities CASCADE')
    # Audit ids appear in history.json, and audits get theirs from the
    # sequence — restart it so the ids are the same on every run.
    ActiveRecord::Base.connection.execute('TRUNCATE audits RESTART IDENTITY')
    Current.reset

    # ------------------------------------------------------------------
    # SEED — the fixture story: meal 42, Jane/Bob/Alice, January 2026.
    # ------------------------------------------------------------------
    community = jane = bob = alice = nil

    clock.travel_to Time.zone.parse('2026-01-01 09:00') do
      community = Community.create!(
        id: 1,
        name: 'Test Community',
        cap: nil,
        timezone: 'America/Los_Angeles'
      )

      unit_a = Unit.create!(id: 1, name: 'A')
      unit_b = Unit.create!(id: 2, name: 'B')
      unit_c = Unit.create!(id: 3, name: 'C')

      jane = Resident.create!(
        id: 1, name: 'Jane Smith', email: 'jane@test.com', password: 'password',
        unit: unit_a,
        multiplier: 2, can_cook: true, vegetarian: false,
        birthday: Date.new(1985, 3, 15)
      )

      bob = Resident.create!(
        id: 2, name: 'Bob Johnson', email: 'bob@test.com', password: 'password',
        unit: unit_b,
        multiplier: 2, can_cook: true, vegetarian: true,
        birthday: Date.new(1990, 7, 22)
      )

      # Alice's birthday falls inside the January view, so she is the
      # calendar's birthday tile.
      alice = Resident.create!(
        id: 3, name: 'Alice Williams', email: 'alice@test.com', password: 'password',
        unit: unit_c,
        multiplier: 2, can_cook: false, vegetarian: false,
        birthday: Date.new(1978, 1, 20)
      )
    end

    meal42 = nil

    clock.travel_to Time.zone.parse('2026-01-10 09:00') do
      # Color, description, and place_value are model-managed; the
      # rotation only needs to exist and own meals 42 and 43.
      rotation = Rotation.create!(id: 10)

      # Meal 41 is in the past on the frozen "today" (2026-01-15); 42 is
      # today's meal; 43 is upcoming. 41 and 43 exist mostly so meal 42
      # has real prev/next ids.
      Meal.create!(id: 41, date: Date.new(2026, 1, 13))
      meal42 = Meal.create!(
        id: 42, date: Date.new(2026, 1, 15),
        description: 'Pasta night with garlic bread', rotation: rotation
      )
      meal43 = Meal.create!(
        id: 43, date: Date.new(2026, 1, 17),
        rotation: rotation
      )

      # The rotation's description is the date range of its meals,
      # computed in an after_save. The meals now exist; save again so
      # the description reflects them, as it does in production.
      rotation.save!

      # Bob cooks meal 43. No amount yet — the meal is in the future.
      Audited.audit_class.as_user(bob) do
        Bill.create!(id: 202, meal: meal43, resident: bob)
        MealResident.create!(
          resident: bob, meal: meal43, multiplier: bob.multiplier
        )
      end

      Event.create!(
        id: 70, title: 'Community Meeting',
        description: 'Monthly community meeting',
        start_date: Time.zone.parse('2026-01-28 19:00'),
        end_date: Time.zone.parse('2026-01-28 21:00')
      )

      CommonHouseReservation.create!(
        id: 50, resident: jane, title: 'Book Club',
        start_date: Time.zone.parse('2026-01-22 19:00'),
        end_date: Time.zone.parse('2026-01-22 21:00')
      )

      GuestRoomReservation.create!(
        id: 60, resident: jane,
        date: Date.new(2026, 1, 25)
      )
    end

    # Meal 42's story, in the order the history modal tells it: Jane signs
    # up and enters her cost, adds a guest, and Alice signs up late.
    clock.travel_to Time.zone.parse('2026-01-14 18:30') do
      Audited.audit_class.as_user(jane) do
        MealResident.create!(
          resident: jane, meal: meal42, multiplier: jane.multiplier
        )
        Bill.create!(
          id: 201, meal: meal42, resident: jane,
          amount: BigDecimal('25.50')
        )
      end
    end

    clock.travel_to Time.zone.parse('2026-01-14 18:35') do
      Audited.audit_class.as_user(jane) do
        Guest.create!(
          id: 101, meal: meal42, resident: jane, multiplier: 2, vegetarian: false
        )
      end
    end

    clock.travel_to Time.zone.parse('2026-01-14 19:00') do
      Audited.audit_class.as_user(alice) do
        MealResident.create!(
          resident: alice, meal: meal42,
          multiplier: alice.multiplier, late: true
        )
      end
    end

    # ------------------------------------------------------------------
    # CAPTURE — real requests through the full controller stack.
    # ------------------------------------------------------------------
    fixtures_dir = Rails.root.join('tests/fixtures')

    clock.travel_to Time.zone.parse('2026-01-15 12:00') do
      session = ActionDispatch::Integration::Session.new(Rails.application)
      headers = { 'Authorization' => "Bearer #{JwtAuth.encode(jane)}" }

      capture = lambda do |path, file|
        Current.reset
        session.get(path, headers: headers)
        abort "GET #{path} returned #{session.response.status}" unless session.response.status == 200

        json = JSON.parse(session.response.body)
        File.write(fixtures_dir.join(file), "#{JSON.pretty_generate(json)}\n")
        puts "  #{file} <- GET #{path}"
      end

      capture.call('/api/v1/communities/1/calendar/2026-01-15', 'calendar.json')
      capture.call('/api/v1/meals/42/cooks', 'meal.json')
      capture.call('/api/v1/meals/42/history', 'history.json')
      capture.call('/api/v1/communities/1/hosts', 'hosts.json')
      capture.call('/api/v1/rotations/10', 'rotation.json')
      capture.call('/api/v1/events/70', 'event.json')
      capture.call('/api/v1/common-house-reservations/50', 'common_house_reservation.json')
      capture.call('/api/v1/guest-room-reservations/60', 'guest_room_reservation.json')
    end

    # Leave the test database the way RSpec expects to find it: empty.
    # The trigger specs (spec/db/) clean tables with delete_all in a
    # fixed order and fail on foreign keys from leftover seed rows.
    ActiveRecord::Base.connection.execute('TRUNCATE communities CASCADE')
    ActiveRecord::Base.connection.execute('TRUNCATE audits RESTART IDENTITY')
    Current.reset

    # Prettier owns JSON formatting in this repo (bin/check runs
    # format:check), so let it format what we wrote.
    system('npx', 'prettier', '--log-level', 'warn', '--write', fixtures_dir.join('*.json').to_s,
           exception: true)

    puts 'Fixtures written.'
  end
end
