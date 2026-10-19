# frozen_string_literal: true

require 'rails_helper'

# bin/update-snapshots deletes the visual goldens and records them again
# on both platforms. Playwright, git and bin/update-linux-snapshots are
# fakes here; the goldens are empty files in the sandbox.
RSpec.describe 'bin/update-snapshots' do
  include_context 'with a script sandbox'

  let(:script) { sandbox.link('bin/update-snapshots') }
  let(:snapshots) { File.join(sandbox.root, 'tests/e2e/visual.spec.js-snapshots') }
  let(:goldens) do
    %w[event-edit event-edit-deleting meal-edit].product(%w[chromium webkit], %w[darwin linux])
                                                .map { |name, browser, os| "#{name}-#{browser}-#{os}.png" }
  end

  before do
    goldens.each { |golden| sandbox.write(File.join(snapshots, golden)) }
    sandbox.write(File.join(snapshots, 'notes.txt'))
    sandbox.fake('npx')
    sandbox.fake('git', sandbox.says(" D tests/e2e/visual.spec.js-snapshots/meal-edit-chromium-darwin.png\n"))
    sandbox.fake_script('bin/update-linux-snapshots')
  end

  def left = Dir.children(snapshots).sort

  it 'deletes every golden, records them on macOS and Linux, and lists what changed' do
    result = sandbox.run(script)

    expect(result).to be_success, result.output
    expect(left).to eq(['notes.txt'])
    expect(sandbox.call_lines.grep_v(/\Arm /)).to eq([
                                                       'npx playwright test tests/e2e/visual.spec.js ' \
                                                       '--update-snapshots --project=chromium --project=webkit',
                                                       'bin/update-linux-snapshots',
                                                       'git status --short tests/e2e/visual.spec.js-snapshots'
                                                     ])
    expect(result.output).to include('Deleted all goldens.', 'meal-edit-chromium-darwin.png')
  end

  it 'deletes only the goldens it names' do
    result = sandbox.run(script, 'event-edit', 'meal-edit')

    expect(result).to be_success, result.output
    expect(left).to eq(%w[event-edit-deleting-chromium-darwin.png event-edit-deleting-chromium-linux.png
                          event-edit-deleting-webkit-darwin.png event-edit-deleting-webkit-linux.png notes.txt])
    expect(result.output).to include('Deleted goldens for: event-edit', 'Deleted goldens for: meal-edit')
  end

  it 'refuses a name with no golden and lists the names there are' do
    result = sandbox.run(script, 'no-such')

    expect(result.exitstatus).to eq(1)
    expect(result.output).to eq("No golden named 'no-such'. The goldens are:\n" \
                                "event-edit\nevent-edit-deleting\nmeal-edit\nnotes.txt\n")
    expect(left.size).to eq(13)
    expect(sandbox.calls_to('npx')).to be_empty
  end

  # A typo in the second name must not leave the first name's goldens
  # deleted and not recorded again.
  it 'checks every name before it deletes any' do
    result = sandbox.run(script, 'meal-edit', 'no-such')

    expect(result.exitstatus).to eq(1)
    expect(left.size).to eq(13)
  end

  # A name that is only the start of other goldens' names would delete
  # nothing and be reported as deleted. The golden would then keep its old
  # image whenever the change is inside the diff tolerance, which is the
  # case the script exists for.
  it 'refuses a name that is only the start of the names of other goldens' do
    result = sandbox.run(script, 'event')

    expect(result.exitstatus).to eq(1)
    expect(result.output).not_to include('Deleted goldens for: event')
  end

  it 'stops when the macOS recording fails, before Linux' do
    sandbox.fake('npx', 'exit 1')

    result = sandbox.run(script)

    expect(result.exitstatus).to eq(1)
    expect(sandbox.calls_to('bin/update-linux-snapshots')).to be_empty
  end
end
