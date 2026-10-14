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

# A bill on `meal` and everyone in `eaters` at the table, then closed.
# Attendance goes on before the close: a closed meal refuses new rows.
def seed_closed_meal(meal:, cook:, amount:, eaters:, guest_of: nil)
  community = cook.community
  FactoryBot.create(:bill, community: community, meal: meal, resident: cook, amount: amount)
  eaters.each do |resident|
    FactoryBot.create(:meal_resident, community: community, meal: meal, resident: resident)
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

  # Meals 3 (2026-01-02), 4 (2026-01-05) and 5 (2026-01-06), in rotation
  # 2. Every meal belongs to a rotation, and a rotation made with its
  # meals is numbered by their dates: rotation 2 is "Rotation 1" and
  # rotation 1 is "Rotation 2". The New Meal form's rotation menu then has
  # a gap between the two (actions.spec.js picks a date in it).
  community.rotations.create!(no_email: true,
                              meals_attributes: [{ date: Date.new(2026, 1, 2) }, { date: Date.new(2026, 1, 5) },
                                                 { date: Date.new(2026, 1, 6) }])

  # A settled period: meal 3, with a bill over the cap, three eaters and a
  # guest, swept by reconciliation 1 (dated SEED_NOW). Both meals are at
  # least 14 days before SEED_NOW (2026-01-20), so a settlement may cover
  # them (Reconciliation::DAYS_TO_WAIT); actions.spec.js settles meal 4.
  seed_closed_meal(meal: Meal.find(3), cook: cook, amount: BigDecimal('75'),
                   eaters: [cook, bob, carol], guest_of: bob)
  Settlement.run!(cutoff: Date.new(2026, 1, 3))

  # Meal 4: closed but not yet settled, so the dashboard's "closed meals"
  # panel and the averages have something to count.
  seed_closed_meal(meal: Meal.find(4), cook: bob, amount: BigDecimal('20'),
                   eaters: [cook, bob])

  # Meal 5: Bob ate, and Alice signed up to cook but has not entered a
  # cost, so a settlement waits for it (ADR 0011 rule 3). The settlement
  # preview lists it, and actions.spec.js marks her cost No cost there.
  seed_closed_meal(meal: Meal.find(5), cook: cook, amount: BigDecimal('0'), eaters: [bob])
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

# Two ledger checks: one clean, one that found differences (id 2), so
# /ledger_check_runs renders both status tags and the run page renders
# its "what disagreed" table with every kind of row: a balance rebuilt
# from bills and sign-ups (one of them with no balance), the sum of one
# person's meal lines, and the sum of all meal lines. Residents 1 and 2
# are Alice and Bob; reconciliation 1 is the seeded settlement.
def seed_ledger_checks
  FactoryBot.create(:ledger_check_run, started_at: SEED_NOW - 1.day - 8.hours,
                                       finished_at: SEED_NOW - 1.day - 8.hours + 3.seconds,
                                       reconciliations_checked: 1)
  settled = SEED_NOW.to_date.iso8601
  FactoryBot.create(:ledger_check_run, mismatch_count: 2, reconciliations_checked: 1,
                                       started_at: SEED_NOW - 8.hours, finished_at: SEED_NOW - 8.hours + 2.seconds,
                                       details: [
                                         { 'reconciliation_id' => 1, 'date' => settled, 'check' => 'recompute',
                                           'differences' => [
                                             { 'resident_id' => 1, 'stored' => '40.0', 'source' => '39.0' },
                                             { 'resident_id' => 2, 'stored' => '-40.0', 'source' => nil }
                                           ] },
                                         { 'reconciliation_id' => 1, 'date' => settled, 'check' => 'line_items',
                                           'differences' => [
                                             { 'resident_id' => 2, 'stored' => '-40.0', 'source' => '-39.98' },
                                             { 'resident_id' => nil, 'stored' => nil, 'source' => '0.01' }
                                           ] }
                                       ])
end

community, cook, bob, carol = seed_people
seed_meals(community, cook, bob, carol)
seed_calendar(community, cook, bob)
seed_ledger_checks

puts "seeded #{conn.current_database}"
