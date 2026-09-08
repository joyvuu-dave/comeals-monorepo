# frozen_string_literal: true

# Deterministic data for the admin Playwright suite (tests/admin).
# Run by tests/admin/server.sh inside a dedicated admin e2e database —
# comeals_admin_e2e in the main checkout and CI, comeals_admin_e2e_<task>
# in an agent worktree (#65) — never against development or test data.
# Every value a test asserts on (dates, emails, names) is set explicitly
# here. The TRUNCATE below wipes the whole database, so this guard must
# stay exact: an admin e2e name, nothing else.
#
# The visual suite (tests/admin/visual.spec.js) photographs every admin
# page, so every page needs a row to show, and every value on a page
# must be the same on every run. server.sh freezes the clock for this
# script and for the server (INTEGRATION_FAKE_TODAY), so created_at
# columns, the settlement date, the ledger check times, and the sign-in
# time Devise writes are all fixed.

conn = ActiveRecord::Base.connection
unless conn.current_database.match?(/\Acomeals_admin_e2e(_[a-z0-9_]+)?\z/)
  raise "refusing to seed #{conn.current_database}: this script is only " \
        'for a comeals_admin_e2e database'
end

tables = conn.tables - %w[schema_migrations ar_internal_metadata]
conn.execute(
  "TRUNCATE #{tables.map { |t| conn.quote_table_name(t) }.join(', ')} " \
  'RESTART IDENTITY CASCADE'
)

# factory_bot_rails auto-loads spec/factories in the test environment;
# find_definitions again would raise DuplicateDefinitionError.
require 'factory_bot'
FactoryBot.find_definitions if FactoryBot.factories.none?

# The frozen "now" from server.sh, in the community's zone.
raise 'tests/admin/seed.rb needs the frozen clock (INTEGRATION_FAKE_TODAY)' if ENV['INTEGRATION_FAKE_TODAY'].blank?

SEED_NOW = Time.current.in_time_zone('America/Los_Angeles')

# The raw token behind the admin password-reset page. Devise stores its
# digest; the visual suite visits /password/edit with the raw value.
ADMIN_RESET_TOKEN = 'admin-e2e-reset-token'

def seed_people
  community = FactoryBot.create(:community, name: 'Admin E2E', cap: BigDecimal('4.50'))

  admin = FactoryBot.create(:admin_user, community: community,
                                         email: 'admin@example.com',
                                         phone: '510-555-2671',
                                         password: 'password', password_confirmation: 'password',
                                         superuser: true)
  admin.update_columns(
    reset_password_token: Devise.token_generator.digest(AdminUser, :reset_password_token, ADMIN_RESET_TOKEN),
    reset_password_sent_at: SEED_NOW
  )
  FactoryBot.create(:admin_user, community: community, email: 'helper@example.com')

  unit_a = FactoryBot.create(:unit, community: community, name: 'A')
  unit_b = FactoryBot.create(:unit, community: community, name: 'B')
  cook = FactoryBot.create(:resident, community: community, unit: unit_a,
                                      name: 'Alice Cook', email: 'alice@example.com',
                                      phone: '510-555-2671', can_cook: true)
  bob = FactoryBot.create(:resident, community: community, unit: unit_b,
                                     name: 'Bob Baker', email: 'bob@example.com', can_cook: true)
  carol = FactoryBot.create(:resident, community: community, unit: unit_b,
                                       name: 'Carol Baker', email: 'carol@example.com',
                                       multiplier: 1, birthday: Date.new(2018, 5, 6), can_cook: false)
  [community, cook, bob, carol]
end

# A meal with a bill and everyone in `eaters` at the table, then closed.
# Attendance goes on before the close: a closed meal refuses new rows.
def seed_closed_meal(date:, cook:, amount:, eaters:, guest_of: nil)
  community = cook.community
  meal = FactoryBot.create(:meal, community: community, date: date)
  FactoryBot.create(:bill, community: community, meal: meal, resident: cook, amount: amount)
  eaters.each do |resident|
    FactoryBot.create(:meal_resident, community: community, meal: meal, resident: resident,
                                      multiplier: resident.multiplier)
  end
  FactoryBot.create(:guest, meal: meal, resident: guest_of) if guest_of
  meal.update!(closed: true)
  meal
end

def seed_meals(community, cook, bob, carol)
  # Meal ids are deterministic thanks to RESTART IDENTITY: 2027-02-04 is
  # meal 1, in rotation 1. admin.spec.js reads both.
  community.rotations.create!(no_email: true,
                              meals_attributes: [{ date: Date.new(2027, 2, 4) }, { date: Date.new(2027, 2, 2) }])
  # Bill id 1, attached to meal 1.
  FactoryBot.create(:bill, community: community, meal: Meal.find(1), resident: cook, amount: BigDecimal('75'))

  # A settled period: meal 3, with a bill over the cap, three eaters and a
  # guest, swept by reconciliation 1 (dated SEED_NOW).
  seed_closed_meal(date: Date.new(2026, 1, 10), cook: cook, amount: BigDecimal('75'),
                   eaters: [cook, bob, carol], guest_of: bob)
  Settlement.run!(cutoff: Date.new(2026, 1, 15), community: community)

  # Meal 4: closed but not yet settled, so the dashboard's "closed meals"
  # panel and the averages have something to count.
  seed_closed_meal(date: Date.new(2026, 1, 17), cook: bob, amount: BigDecimal('20'),
                   eaters: [cook, bob])
  BalanceRecalculation.call(community: community)
end

def seed_calendar(community, cook, bob)
  FactoryBot.create(:event, community: community, title: 'Maintenance Committee Meeting',
                            description: 'Monthly, in the common house.',
                            start_date: SEED_NOW.change(day: 3, month: 2, hour: 19),
                            end_date: SEED_NOW.change(day: 3, month: 2, hour: 21))
  FactoryBot.create(:common_house_reservation, community: community, resident: cook, title: 'Book Club',
                                               start_date: SEED_NOW.change(day: 5, month: 2, hour: 18),
                                               end_date: SEED_NOW.change(day: 5, month: 2, hour: 20))
  FactoryBot.create(:guest_room_reservation, community: community, resident: bob, date: Date.new(2026, 2, 14))
end

# Two ledger checks: one clean, one that found a difference (id 2), so
# /ledger_check_runs renders both status tags and the run page renders
# its "what disagreed" table.
def seed_ledger_checks
  FactoryBot.create(:ledger_check_run, started_at: SEED_NOW - 1.day - 8.hours,
                                       finished_at: SEED_NOW - 1.day - 8.hours + 3.seconds,
                                       reconciliations_checked: 1)
  FactoryBot.create(:ledger_check_run, :with_mismatches,
                    started_at: SEED_NOW - 8.hours, finished_at: SEED_NOW - 8.hours + 2.seconds,
                    reconciliations_checked: 1)
end

community, cook, bob, carol = seed_people
seed_meals(community, cook, bob, carol)
seed_calendar(community, cook, bob)
seed_ledger_checks

puts "seeded #{conn.current_database}"
