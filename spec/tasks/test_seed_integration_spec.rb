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

  it 'refuses to run outside the test environment' do
    allow(Rails).to receive(:env).and_return(ActiveSupport::EnvironmentInquirer.new('development'))

    expect { task.execute }.to raise_error(SystemExit).and output(/Must run in test environment/).to_stderr
    expect(written).to be_empty
  end
end
