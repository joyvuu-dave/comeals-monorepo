# frozen_string_literal: true

require 'rails_helper'

# bin/update-linux-snapshots rewrites the Linux goldens through
# bin/visual-linux, which is a fake here (it has its own spec). The
# script's first line names /bin/bash, which is bash 3.2 on a Mac, so the
# spec runs it with the bash on the PATH.
RSpec.describe 'bin/update-linux-snapshots',
               bash_coverage: BashCoverage.new('spec/bin/update_linux_snapshots_spec.rb') do
  include_context 'with a script sandbox'

  let(:script) { sandbox.link('bin/update-linux-snapshots') }

  it 'runs bin/visual-linux with --update and says to review the changed images' do
    sandbox.fake_script('bin/visual-linux')

    result = sandbox.run(sandbox.bash, script)

    expect(result).to be_success, result.output
    expect(sandbox.call_lines).to eq(['bin/visual-linux --update'])
    expect(result.output).to include('Review the changed PNGs, then commit them')
  end

  it 'stops with the failure when bin/visual-linux fails' do
    sandbox.fake_script('bin/visual-linux', 'exit 1')

    result = sandbox.run(sandbox.bash, script)

    expect(result.exitstatus).to eq(1)
    expect(result.output).not_to include('Review the changed PNGs')
  end
end
