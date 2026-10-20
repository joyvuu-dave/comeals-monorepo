# frozen_string_literal: true

require 'rails_helper'

# bin/smoke hands the site's address to the browser smoke test
# (tests/smoke/smoke.js), run here with a fake node.
RSpec.describe 'bin/smoke', bash_coverage: BashCoverage.new('spec/bin/smoke_spec.rb') do
  include_context 'with a script sandbox'

  let(:sandbox) { new_sandbox(real: %w[python3]) }

  before do
    sandbox.note_env('SMOKE_URL')
    sandbox.rule('node', 'tests/smoke/smoke.js')
  end

  def node_calls = sandbox.calls_to('node')

  it 'smokes production when given no address' do
    result = sandbox.run_script('bin/smoke')

    expect(result.exitstatus).to eq(0)
    expect(node_calls.map { [it.args, it.env] })
      .to eq([[['tests/smoke/smoke.js'], { 'SMOKE_URL' => 'https://comeals.com' }]])
  end

  it 'smokes the address it is given' do
    sandbox.run_script('bin/smoke', 'http://localhost:3000')

    expect(node_calls.pluck(:env)).to eq([{ 'SMOKE_URL' => 'http://localhost:3000' }])
  end

  it 'fails when the smoke test fails' do
    sandbox.rule('node', 'tests/smoke/smoke.js', err: 'the login page did not render', exit: 1)

    result = sandbox.run_script('bin/smoke')

    expect(result.exitstatus).to eq(1)
    expect(result.err).to include('the login page did not render')
  end
end
