# frozen_string_literal: true

require 'rails_helper'

# bin/smoke hands the site's address to the browser smoke test
# (tests/smoke/smoke.js), run here with a fake node.
RSpec.describe 'bin/smoke', bash_coverage: BashCoverage.new('spec/bin/smoke_spec.rb') do
  let(:sandbox) { ScriptSandbox.new(fakes: %w[node], coverage: self.class.metadata[:bash_coverage]) }

  after { sandbox.cleanup }

  # Holds the scripts BashCoverage::FILES names for this file at 100% of
  # their lines. It runs only when every example in the file ran, so one
  # example on its own can still pass (spec/bin/deploy_spec.rb).
  after(:context) do
    ran_all = self.class.descendant_filtered_examples.size == self.class.descendants.sum { it.examples.size }
    self.class.metadata[:bash_coverage].check! if ran_all
  end

  before do
    sandbox.record_env('SMOKE_URL')
    sandbox.fake('node', 'tests/smoke/smoke.js')
  end

  def node_calls = sandbox.calls.select { it[:command] == 'node' }

  it 'smokes production when given no address' do
    result = sandbox.run('bin/smoke')

    expect(result.exitstatus).to eq(0)
    expect(node_calls.map { [it[:args], it[:env]] })
      .to eq([[['tests/smoke/smoke.js'], { 'SMOKE_URL' => 'https://comeals.com' }]])
  end

  it 'smokes the address it is given' do
    sandbox.run('bin/smoke', 'http://localhost:3000')

    expect(node_calls.pluck(:env)).to eq([{ 'SMOKE_URL' => 'http://localhost:3000' }])
  end

  it 'fails when the smoke test fails' do
    sandbox.fake('node', 'tests/smoke/smoke.js', err: 'the login page did not render', exit: 1)

    result = sandbox.run('bin/smoke')

    expect(result.exitstatus).to eq(1)
    expect(result.err).to include('the login page did not render')
  end
end
