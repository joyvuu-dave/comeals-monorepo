# frozen_string_literal: true

require 'rails_helper'

# bin/mutant copies the test database once per worker, runs mutant, drops
# the copies, and checks the session mutant wrote against the accepted
# survivors. Bundler, createdb, dropdb and bin/mutant-survivors are fakes
# here; the fake mutant writes an empty session file.
RSpec.describe 'bin/mutant', bash_coverage: BashCoverage.new('spec/bin/mutant_spec.rb') do
  include_context 'with a script sandbox'

  let(:script) { sandbox.link('bin/mutant') }
  let(:write_session) { 'touch .mutant/results/s.json.gz' }

  before do
    sandbox.link('bin/lib/output.sh')
    sandbox.fake('bundle', sandbox.answers({ 'exec rails runner *' => 'printf comeals_test_x',
                                             'exec mutant *' => write_session }),
                 notes: %w[RAILS_ENV MUTANT MUTANT_JOBS])
    sandbox.fake_script('bin/mutant-survivors')
    sandbox.fake('createdb')
    sandbox.fake('dropdb')
  end

  def workers(command, count)
    (0...count).map { |n| "#{command} comeals_test_x_#{n}" }
  end

  it 'copies the test database for four workers, runs mutant, then drops the copies' do
    result = sandbox.run(script, env: { 'MUTANT_JOBS' => nil })

    expect(result).to be_success, result.output
    expect(sandbox.call_lines).to eq([
                                       'bundle exec rails db:prepare',
                                       'bundle exec rails runner print ActiveRecord::Base.connection_db_config.database',
                                       *workers('dropdb --if-exists', 4),
                                       *(0...4).map { |n| "createdb --template comeals_test_x comeals_test_x_#{n}" },
                                       'bundle exec mutant run --jobs 4',
                                       'bin/mutant-survivors --full .mutant/results/s.json.gz',
                                       *workers('dropdb --if-exists', 4)
                                     ])
    expect(sandbox.calls_to('bundle').map(&:env).uniq).to eq([{ 'RAILS_ENV' => 'test', 'MUTANT' => '1' }])
    expect(result.output).to include('comeals_test_x is migrated', 'comeals_test_x_0 .. comeals_test_x_3 copied')
  end

  # mutant must not see MUTANT_JOBS: it would build a config from it that
  # counts a timeout as a kill (spec/config/mutant_timeout_spec.rb).
  it 'takes the worker count from MUTANT_JOBS and hides the variable from mutant' do
    result = sandbox.run(script, env: { 'MUTANT_JOBS' => '2' })

    expect(result).to be_success, result.output
    mutant = sandbox.calls_to('bundle').find { |call| call.args.include?('mutant') }
    expect(mutant.args).to eq(%w[exec mutant run --jobs 2])
    expect(mutant.env).not_to have_key('MUTANT_JOBS')
    expect(sandbox.calls_to('createdb').size).to eq(2)
  end

  it "passes mutant's own arguments after --" do
    sandbox.run(script, '--', 'Settlement.allocate_to_cents')

    expect(sandbox.call_lines).to include('bundle exec mutant run --jobs 4 Settlement.allocate_to_cents')
    # Not every subject ran, so an entry for another subject is not stale.
    expect(sandbox.call_lines).to include('bin/mutant-survivors .mutant/results/s.json.gz')
  end

  it 'passes arguments without -- too' do
    sandbox.run(script, 'Settlement.allocate_to_cents')

    expect(sandbox.call_lines).to include('bundle exec mutant run --jobs 4 Settlement.allocate_to_cents')
  end

  # Mutant exits 1 whenever a mutation lives; the accepted list decides.
  it 'takes the answer from the survivors check, not from mutant' do
    sandbox.fake('bundle', sandbox.answers({ 'exec rails runner *' => 'printf comeals_test_x',
                                             'exec mutant *' => "#{write_session}; exit 1" }))

    result = sandbox.run(script, env: { 'MUTANT_JOBS' => '1' })

    expect(result).to be_success, result.output
    expect(sandbox.call_lines.last).to eq('dropdb --if-exists comeals_test_x_0')
  end

  it 'fails when the survivors check fails' do
    sandbox.fake_script('bin/mutant-survivors', 'exit 1')

    result = sandbox.run(script, env: { 'MUTANT_JOBS' => '1' })

    expect(result.exitstatus).to eq(1)
    expect(sandbox.call_lines.last).to eq('dropdb --if-exists comeals_test_x_0')
  end

  it 'drops the copies and fails when mutant wrote no session' do
    sandbox.fake('bundle', sandbox.answers({ 'exec rails runner *' => 'printf comeals_test_x',
                                             'exec mutant *' => 'exit 1' }))

    result = sandbox.run(script, env: { 'MUTANT_JOBS' => '1' })

    expect(result.exitstatus).to eq(1)
    expect(result.output).to include('mutant wrote no session, so it did not finish (exit 1)')
    expect(sandbox.call_lines('bin/mutant-survivors')).to be_empty
    expect(sandbox.call_lines.last).to eq('dropdb --if-exists comeals_test_x_0')
  end

  # A session from an earlier run is not this run's result.
  it 'ignores a session older than this run' do
    sandbox.write('.mutant/results/old.json.gz')
    sandbox.fake('bundle', sandbox.answers({ 'exec rails runner *' => 'printf comeals_test_x',
                                             'exec mutant *' => 'exit 1' }))

    expect(sandbox.run(script, env: { 'MUTANT_JOBS' => '1' }).exitstatus).to eq(1)
  end

  it 'goes on when a copy to drop is not there' do
    sandbox.fake('dropdb', 'exit 1')

    expect(sandbox.run(script, env: { 'MUTANT_JOBS' => '1' })).to be_success
  end

  it 'stops before mutant when a copy cannot be made' do
    sandbox.fake('createdb', 'exit 1')

    result = sandbox.run(script)

    expect(result.exitstatus).to eq(1)
    expect(sandbox.call_lines.grep(/mutant run/)).to be_empty
  end
end
