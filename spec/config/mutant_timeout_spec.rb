# frozen_string_literal: true

require 'rails_helper'
require 'open3'

# .mutant.yml says a mutation that no example fails before the timeout
# counts as not killed (coverage_criteria: timeout: false). Mutant 0.17
# drops that setting when MUTANT_JOBS is in its environment: it reads the
# variable into a config with the gem's default criteria, where a timeout
# counts as killed, and that config is merged over the file's. bin/mutant
# exported MUTANT_JOBS until 2026-09-28, so every run counted a timeout
# as a kill. In the money stage run of that day, 140 mutations timed out
# after every example they reached had passed, and all 140 were counted
# as killed.
#
# This runs bin/mutant with stand-ins for bundle, createdb and dropdb on
# the PATH, so nothing real is migrated, copied or mutated. The stand-in
# bundle writes down what the mutant command was given.
RSpec.describe 'bin/mutant' do
  let(:dir) { Dir.mktmpdir }

  after { FileUtils.remove_entry(dir) }

  def stand_in(name, body)
    path = File.join(dir, name)
    File.write(path, "#!/usr/bin/env bash\n#{body}\n")
    File.chmod(0o755, path)
  end

  def run_bin_mutant(env)
    record = File.join(dir, 'mutant-call')
    stand_in('bundle', <<~BASH)
      if [ "$2" = "mutant" ]; then
        { echo "MUTANT_JOBS=${MUTANT_JOBS-unset}"; echo "args=${*:3}"; } > #{record}
      elif [ "$3" = "runner" ]; then
        printf stand_in_test_database
      fi
      exit 0
    BASH
    stand_in('createdb', 'exit 0')
    stand_in('dropdb', 'exit 0')

    _output, status = Open3.capture2e(env.merge('PATH' => "#{dir}:#{ENV.fetch('PATH')}"),
                                      Rails.root.join('bin/mutant').to_s, '--', 'Settlement.run!')
    expect(status).to be_success
    File.read(record).lines.map(&:chomp)
  end

  it 'passes the worker count as --jobs and keeps MUTANT_JOBS out of mutant' do
    expect(run_bin_mutant('MUTANT_JOBS' => '2')).to eq(['MUTANT_JOBS=unset', 'args=run --jobs 2 Settlement.run!'])
  end

  it 'uses four workers when MUTANT_JOBS is not set' do
    expect(run_bin_mutant('MUTANT_JOBS' => nil)).to eq(['MUTANT_JOBS=unset', 'args=run --jobs 4 Settlement.run!'])
  end
end
