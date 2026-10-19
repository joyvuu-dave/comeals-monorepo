# frozen_string_literal: true

require 'rails_helper'
require 'rake'

# bin/check runs test:generate_fixtures in its own process and fails when
# tests/fixtures/ changes. Here it runs inside the example's transaction,
# and the files it writes are caught instead of written, so this spec never
# changes the repository. What it would have written must be the JSON that
# is committed: the task pins every id and every clock so two runs agree.
RSpec.describe 'test:generate_fixtures', type: :task do
  let(:task) { Rake::Task['test:generate_fixtures'] }
  let(:fixtures_dir) { Rails.root.join('tests/fixtures') }
  let(:written) { {} }
  # The rake task's block runs with the top-level object as self, so its
  # call to `system` (Prettier) goes to that object.
  let(:main) { TOPLEVEL_BINDING.receiver }

  before(:all) { RakeTasks.ensure_loaded }

  before do
    allow(File).to receive(:write).and_call_original
    in_fixtures = satisfy { |path| path.to_s.start_with?("#{fixtures_dir}/") }
    allow(File).to receive(:write).with(in_fixtures, anything) do |path, content|
      written[Pathname(path).basename.to_s] = content
    end
    allow(main).to receive(:system)
  end

  it 'captures each API answer the mocked E2E suite serves, the same as the committed files', :aggregate_failures do
    expect { task.execute }.to output(/Fixtures written\./).to_stdout

    expect(written.keys).to match_array(%w[calendar.json meal.json history.json hosts.json rotation.json event.json
                                           common_house_reservation.json guest_room_reservation.json])
    written.each do |name, content|
      expect(JSON.parse(content)).to eq(JSON.parse(fixtures_dir.join(name).read)), "#{name} differs"
    end
    expect(main).to have_received(:system)
      .with('npx', 'prettier', '--log-level', 'warn', '--write', fixtures_dir.join('*.json').to_s, exception: true)
    expect(Community.count).to eq(0)
  end

  it 'stops when a request does not answer 200' do
    allow(JwtAuth).to receive(:encode).and_return('not-a-token')

    expect { task.execute }.to raise_error(SystemExit)
      .and output(%r{GET /api/v1/communities/1/calendar/2026-01-15 returned 401}).to_stderr
    expect(written).to be_empty
  end

  it 'refuses to run outside the test environment' do
    allow(Rails).to receive(:env).and_return(ActiveSupport::EnvironmentInquirer.new('development'))

    expect { task.execute }.to raise_error(SystemExit).and output(/Must run in test environment/).to_stderr
    expect(main).not_to have_received(:system)
  end
end
