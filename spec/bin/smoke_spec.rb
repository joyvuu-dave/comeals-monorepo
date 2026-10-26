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

  # The callers (bin/deploy, the Deploy and Rollback workflows,
  # bin/staging-rehearsal) tell a refused login from a broken site by
  # this code alone.
  it 'ends with code 2 when the site refused a smoke login' do
    sandbox.rule('node', 'tests/smoke/smoke.js', err: 'SMOKE LOGIN REFUSED against https://comeals.com:', exit: 2)

    result = sandbox.run_script('bin/smoke')

    expect(result.exitstatus).to eq(2)
    expect(result.err).to include('SMOKE LOGIN REFUSED')
  end

  # The codes are written down once, at the top of bin/smoke, and
  # tests/smoke/checks.js (EXIT) uses the same numbers.
  it 'says what each exit code means at its top' do
    header = Rails.root.join('bin/smoke').read.lines.take_while { it.start_with?('#') }.join

    expect(header).to include(
      "# Exit codes:\n" \
      "#   0  Every check passed.\n" \
      "#   1  A check failed: the site is broken. The smoke test also ends\n" \
      "#      with 1 when it could not run at all (no browser, say).\n" \
      "#   2  The site answered and refused a login: the smoke credentials\n" \
      "#      are wrong. Every check that could run passed, but the checks\n" \
      "#      behind that login did not run, so this is not a pass either.\n" \
      "#   Any other code: the smoke test could not run (127: no node).\n" \
      "# The callers treat every code but 0 and 2 as a broken site.\n"
    )
    expect(Rails.root.join('tests/smoke/checks.js').read)
      .to include('const EXIT = Object.freeze({ passed: 0, broken: 1, loginRefused: 2 });')
  end
end
