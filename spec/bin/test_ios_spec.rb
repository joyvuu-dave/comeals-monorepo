# frozen_string_literal: true

require 'rails_helper'

# bin/test-ios runs tests/ios/check.mjs (real Safari in the iOS
# simulators) through bin/test-integration, which seeds the database and
# starts the server. Here xcrun and bin/test-integration are fakes.
RSpec.describe 'bin/test-ios', bash_coverage: BashCoverage.new('spec/bin/test_ios_spec.rb') do
  include_context 'with a script sandbox'

  let(:script) { sandbox.link('bin/test-ios') }

  it 'runs bin/test-integration with the iOS check as its runner, and passes on its arguments and exit code' do
    sandbox.fake('xcrun')
    sandbox.fake_script('bin/test-integration', 'exit 4', notes: %w[INTEGRATION_RUNNER])

    result = sandbox.run(script, 'extra')

    expect(result.exitstatus).to eq(4)
    call = sandbox.calls_to('bin/test-integration').sole
    expect(call.args).to eq(['extra'])
    expect(call.env).to eq('INTEGRATION_RUNNER' => 'node tests/ios/check.mjs')
  end

  it 'refuses to run without Xcode and its simulators' do
    sandbox.fake('xcrun', 'exit 1')
    sandbox.fake_script('bin/test-integration')

    result = sandbox.run(script)

    expect(result.exitstatus).to eq(1)
    expect(result.output).to include('bin/test-ios needs Xcode and its iOS simulators')
    expect(sandbox.calls_to('bin/test-integration')).to be_empty
  end
end
