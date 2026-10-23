# frozen_string_literal: true

require 'rails_helper'

# bin/lib/playwright-install, which every workflow uses to install
# Playwright's browsers or the system packages they need (#240). Those
# packages come from the runner's apt mirror. When the mirror stopped
# sending, the install waited until the whole job ran out of time. `timeout` is a
# fake here: the examples say how each try ended.
RSpec.describe 'bin/lib/playwright-install', bash_coverage: BashCoverage.new('spec/bin/playwright_install_spec.rb') do
  include_context 'with a script sandbox'

  let(:try) { 'timeout --kill-after=30s 8m npx playwright install-deps chromium webkit' }
  let(:lock_check) { 'sudo fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock' }

  # fuser exits 1 when no process holds the files: apt is done.
  def apt_done
    sandbox.rule('sleep')
    sandbox.rule('sudo')
    sandbox.rule('sudo', 'fuser *', exit: 1)
  end

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
    apt_done
    sandbox.rule('timeout')
    sandbox.rule('timeout', exit: 124, once: true)

    result = install

    expect(result.exitstatus).to eq(0)
    expect(sandbox.call_lines('timeout')).to eq([try, try])
    expect(result.err).to eq("npx playwright install-deps chromium webkit ran out of time (8m) on try 1 of 2.\n")
  end

  # timeout cannot stop the apt-get that Playwright starts as root, so after
  # a try that ran out of time apt can still hold dpkg's lock. A second try
  # then fails at once: "Could not get lock /var/lib/dpkg/lock-frontend"
  # (CI, 2026-10-23). So the second try waits for that apt to finish, and
  # lets dpkg finish any package it left half set up.
  it 'waits until the first try\'s apt lets go of the dpkg lock before trying again' do
    apt_done
    sandbox.rule('sudo', 'fuser *', exit: 0, once: true)
    sandbox.rule('sudo', 'fuser *', exit: 0, once: true)
    sandbox.rule('timeout')
    sandbox.rule('timeout', exit: 124, once: true)

    result = install

    expect(result.exitstatus).to eq(0)
    expect(sandbox.call_lines.grep_v(/\Asleep /)).to eq(
      [try, lock_check, lock_check, lock_check, 'sudo dpkg --configure -a', try]
    )
    expect(sandbox.call_lines('sleep')).to eq(['sleep 5', 'sleep 5'])
  end

  it 'gives up when apt still holds the lock after the time limit' do
    apt_done
    sandbox.rule('sudo', 'fuser *', exit: 0)
    sandbox.rule('timeout', exit: 124)

    result = install(env: { 'PLAYWRIGHT_INSTALL_MINUTES' => '1' })

    expect(result.exitstatus).to eq(1)
    expect(sandbox.call_lines('timeout').size).to eq(1)
    expect(sandbox.call_lines('sleep').size).to eq(12)
    expect(result.err).to end_with(
      "apt still holds the dpkg lock 1m after try 1 of 2 ended, so a second try cannot run.\n"
    )
  end

  it 'fails after two tries that do not work, and says how each one ended' do
    apt_done
    sandbox.rule('timeout', exit: 1, once: true)
    sandbox.rule('timeout', exit: 124, once: true)

    result = install

    expect(result.exitstatus).to eq(1)
    expect(sandbox.call_lines('timeout')).to eq([try, try])
    expect(result.err).to eq(<<~ERR)
      npx playwright install-deps chromium webkit ran out of time (8m) on try 1 of 2.
      npx playwright install-deps chromium webkit failed (exit 1) on try 2 of 2.
    ERR
  end

  it 'takes another time limit from PLAYWRIGHT_INSTALL_MINUTES' do
    sandbox.rule('timeout')

    install(env: { 'PLAYWRIGHT_INSTALL_MINUTES' => '3' })

    expect(sandbox.call_lines('timeout')).to eq([try.sub(' 8m ', ' 3m ')])
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
