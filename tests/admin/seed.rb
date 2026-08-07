# frozen_string_literal: true

# Deterministic data for the admin Playwright suite (tests/admin).
# Run by tests/admin/server.sh inside the dedicated comeals_admin_e2e
# database, never against development or test data. Every value a test
# asserts on (dates, emails, names) is set explicitly here.

conn = ActiveRecord::Base.connection
unless conn.current_database == 'comeals_admin_e2e'
  raise "refusing to seed #{conn.current_database}: this script is only " \
        'for the comeals_admin_e2e database'
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

community = FactoryBot.create(:community, name: 'Admin E2E')

FactoryBot.create(:admin_user, community: community,
                               email: 'admin@example.com',
                               password: 'password', password_confirmation: 'password',
                               superuser: true)

unit = FactoryBot.create(:unit, community: community, name: 'A')
cook = FactoryBot.create(:resident, community: community, unit: unit,
                                    name: 'Alice Cook', can_cook: true)

# Meal ids are deterministic thanks to RESTART IDENTITY: this one is 1.
meal = FactoryBot.create(:meal, community: community, date: Date.new(2027, 2, 4))
FactoryBot.create(:meal, community: community, date: Date.new(2027, 2, 2))

# Bill id 1, attached to meal 1.
FactoryBot.create(:bill, community: community, meal: meal, resident: cook,
                         amount: BigDecimal('75'))

# One ledger check run, so /ledger_check_runs renders a status tag.
FactoryBot.create(:ledger_check_run)

puts "seeded #{conn.current_database}"
