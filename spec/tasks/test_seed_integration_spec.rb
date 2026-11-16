# frozen_string_literal: true

require 'rails_helper'
require 'rake'

# bin/test-integration runs test:seed_integration in its own process, before
# it starts the server the Playwright integration suite talks to. Here it
# runs inside the example's transaction, so its rows are rolled back, and
# the file it writes for Playwright (tmp/integration_auth.json) is caught
# instead of written, so a running integration suite keeps its own.
RSpec.describe 'test:seed_integration', type: :task do
  let(:task) { Rake::Task['test:seed_integration'] }
  let(:auth_file) { Rails.root.join('tmp/integration_auth.json') }
  let(:written) { {} }

  before(:all) { RakeTasks.ensure_loaded }

  before do
    allow(File).to receive(:write).and_call_original
    allow(File).to receive(:write).with(auth_file, anything) { |path, content| written[path] = content }
  end

  def seed
    expect { task.execute }.to output(/Integration seed complete/).to_stdout
    JSON.parse(written.fetch(auth_file), symbolize_names: true)
  end

  # One run, many checks: each run of the task takes about two seconds.
  it 'writes the ids, dates and token Playwright reads, for rows that exist', :aggregate_failures do
    auth = seed

    jane = Resident.find(auth[:resident_id])
    expect([jane.name, JwtAuth.authenticate(auth[:token])]).to eq(['Jane Smith', jane])
    expect(Resident.find(auth[:bob_id]).email).to eq(auth[:bob_email])
    expect(Resident.find(auth[:diana_id]).active).to be(false)
    expect(auth[:community_id]).to eq(Community.instance.id)
    expect(CommonHouseLogin.sole.authenticate(auth[:common_house_password])).to eq(CommonHouseLogin.sole)
    expect(auth[:common_house_email]).to eq(CommonHouseLogin::EMAIL)

    meals = auth[:meals].transform_values { |meal| Meal.find(meal[:id]) }
    expect(meals.transform_values { |meal| meal.date.iso8601 }).to eq(auth[:meals].transform_values { |m| m[:date] })
    expect(meals.select { |_, meal| meal.reconciliation_id }.keys).to eq([:reconciled])
    expect(meals[:today].date).to eq(Community.instance.today)
    expect(meals[:closed].closed).to be(true)

    # No rotation's place equals its id, so a modal that shows the id
    # instead of the place fails a test.
    rotations = auth[:rotations].values
    expect(rotations.pluck(:place_value)).to eq([2, 3])
    expect(rotations).to all(satisfy { |rotation| Rotation.find(rotation[:id]).place_value == rotation[:place_value] })
    expect(rotations).to all(satisfy { |rotation| rotation[:id] != rotation[:place_value] })
  end

  # The check above that no rotation's id equals its place holds only
  # when ids start where a new database starts them. Earlier examples use
  # up ids, and a sequence does not go back on a rollback, so the seed
  # restarts them (#267).
  it 'starts the ids again, whatever ids were used before it' do
    ActiveRecord::Base.connection.execute("SELECT setval('rotations_id_seq', 500)")

    expect(seed[:rotations].values.pluck(:id)).to all(be < 500)
  end

  # The seed starts the ids again and the suite's clock is frozen, so a
  # row an earlier run left behind can look like one this run makes. A
  # guest removal's request key is "remove-guest-<id>": a key left from the
  # last run answered this run's removal of the new guest with that id
  # with the saved 200, and removed nothing (#295). So the seed empties
  # every table, not a list of them, the way tests/admin/seed.rb does.
  it 'empties every table, including those no foreign key reaches' do
    conn = ActiveRecord::Base.connection
    conn.execute(<<~SQL.squish)
      INSERT INTO request_keys (sender, key, request_sha256, status, body, created_at)
      VALUES ('Resident:1', 'a key only this example writes', '#{'0' * 64}', 200, '{}', now())
    SQL
    conn.execute("INSERT INTO throttle_counts (key, count, expires_at) VALUES ('a', 1, now() + interval '1 hour')")

    seed

    expect(conn.select_value('SELECT count(*) FROM request_keys')).to eq(0)
    expect(conn.select_value('SELECT count(*) FROM throttle_counts')).to eq(0)
  end

  it 'refuses to run outside the test environment' do
    allow(Rails).to receive(:env).and_return(ActiveSupport::EnvironmentInquirer.new('development'))

    expect { task.execute }.to raise_error(SystemExit).and output(/Must run in test environment/).to_stderr
    expect(written).to be_empty
  end
end
