# frozen_string_literal: true

require 'rails_helper'

# bin/visual-coverage, the screen-state measure (bin/check's "Screen
# states" step). Playwright and node are fakes here.
RSpec.describe 'bin/visual-coverage', bash_coverage: BashCoverage.new('spec/bin/visual_coverage_spec.rb') do
  include_context 'with a script sandbox'

  let(:script) { sandbox.link('bin/visual-coverage') }

  before do
    sandbox.fake('npx', notes: %w[VISUAL_COVERAGE PLAYWRIGHT_SKIP_VISUAL])
    sandbox.fake('node')
    sandbox.write('tmp/visual-coverage/build/old.js')
  end

  it 'deletes the last build, runs the visual spec with the counters on, then reports' do
    result = sandbox.run(script, env: { 'PLAYWRIGHT_SKIP_VISUAL' => '1' })

    expect(result).to be_success, result.output
    expect(sandbox.call_lines).to eq([
                                       'rm -rf tmp/visual-coverage',
                                       'npx playwright test tests/e2e/visual.spec.js --project chromium',
                                       'node tests/helpers/visual_coverage_report.js'
                                     ])
    expect(sandbox.calls_to('npx').first.env).to eq('VISUAL_COVERAGE' => '1')
    expect(File).not_to exist(File.join(sandbox.root, 'tmp/visual-coverage'))
  end

  it 'stops with the exit code of a failed Playwright run, before the report' do
    sandbox.fake('npx', 'exit 3')

    result = sandbox.run(script)

    expect(result.exitstatus).to eq(3)
    expect(sandbox.calls_to('node')).to be_empty
  end
end
