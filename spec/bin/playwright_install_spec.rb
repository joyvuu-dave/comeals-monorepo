# frozen_string_literal: true

require 'rails_helper'

# bin/lib/playwright-install, which every workflow uses to install
# Playwright's browsers or the system packages they need (#240). Those
# packages come from the runner's apt mirror. When the mirror stopped
# sending, the install waited until the whole job ran out of time. `timeout` is a
# fake here: the examples say how each try ended.
RSpec.describe 'bin/lib/playwright-install', bash_coverage: BashCoverage.new('spec/bin/playwright_install_spec.rb') do
  include_context 'with a script sandbox'

  let(:try) { 'timeout --kill-after=30s 5m npx playwright install-deps chromium webkit' }

  def install(env: {}) = sandbox.run_script('bin/lib/playwright-install', 'install-deps', 'chromium', 'webkit', env:)

  it 'runs the install once, with a time limit, when it works' do
    sandbox.rule('timeout')

    result = install

    expect(result.exitstatus).to eq(0)
    expect(sandbox.call_lines('timeout')).to eq([try])
  end

  # timeout exits 124 when it stopped the command. The rule added last
  # answers first.
  it 'tries once more when the first try runs out of time' do
    sandbox.rule('timeout')
    sandbox.rule('timeout', exit: 124, once: true)

    result = install

    expect(result.exitstatus).to eq(0)
    expect(sandbox.call_lines('timeout')).to eq([try, try])
    expect(result.err).to eq("npx playwright install-deps chromium webkit ran out of time (5m) on try 1 of 2.\n")
  end

  it 'fails after two tries that do not work, and says how each one ended' do
    sandbox.rule('timeout', exit: 1, once: true)
    sandbox.rule('timeout', exit: 124, once: true)

    result = install

    expect(result.exitstatus).to eq(1)
    expect(sandbox.call_lines('timeout')).to eq([try, try])
    expect(result.err).to eq(<<~ERR)
      npx playwright install-deps chromium webkit ran out of time (5m) on try 1 of 2.
      npx playwright install-deps chromium webkit failed (exit 1) on try 2 of 2.
    ERR
  end

  it 'takes another time limit from PLAYWRIGHT_INSTALL_MINUTES' do
    sandbox.rule('timeout')

    install(env: { 'PLAYWRIGHT_INSTALL_MINUTES' => '8' })

    expect(sandbox.call_lines('timeout')).to eq([try.sub(' 5m ', ' 8m ')])
  end

  # Every Playwright install in a workflow goes through the script, so no
  # install can wait for the whole job's time again.
  it 'is the only way the workflows install Playwright' do
    workflows = Rails.root.glob('.github/workflows/*.yml')
    runs = workflows.flat_map do |file|
      YAML.safe_load_file(file.to_s)['jobs'].values.flat_map { it['steps'] }.filter_map { it['run'] }
    end
    installs = runs.flat_map(&:lines).map(&:strip).grep(/playwright[ -]install/)

    expect(installs).not_to be_empty
    expect(installs.grep_v(%r{\Abin/lib/playwright-install })).to eq([])
  end
end
