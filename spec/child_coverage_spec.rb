# frozen_string_literal: true

require 'rails_helper'
require 'open3'

# spec/child_coverage.rb: the counts of the bin/ scripts' processes are
# added to this run's result, and only this run's.
RSpec.describe ChildCoverage do
  let(:base) { Dir.mktmpdir }
  let(:script) { File.join(base, 'script.rb') }

  around do |example|
    saved = ENV.values_at('CHILD_COVERAGE_DIR', 'CHILD_COVERAGE_RUNNER')
    example.run
  ensure
    ENV['CHILD_COVERAGE_DIR'], ENV['CHILD_COVERAGE_RUNNER'] = saved
    FileUtils.remove_entry(base)
  end

  # Writes counts for one file into a run's folder, the way a script's
  # process does.
  def write_counts(dir, lines)
    File.binwrite(File.join(dir, "#{lines.object_id}.marshal"), Marshal.dump(script => { lines: lines }))
  end

  it 'gives each run a folder of its own' do
    first = described_class.start_run(base)
    second = described_class.start_run(base)

    expect(first).not_to eq(second)
    expect(ENV.fetch('CHILD_COVERAGE_DIR')).to eq(second)
  end

  it "adds up the counts in this run's folder and leaves out an earlier run's" do
    earlier = described_class.start_run(base)
    write_counts(earlier, [9, 9, 9])
    now = described_class.start_run(base)
    write_counts(now, [1, 0, nil])
    write_counts(now, [1, 2, nil])

    expect(described_class.read(now)).to eq(script => { lines: [2, 2, nil] })
  end

  it 'adds branch counts branch by branch' do
    branch = [:if, 0, 1, 0, 3, 3]
    first = { script => { lines: [1],
                          branches: { branch => { [:then, 1, 2, 2, 2, 8] => 1, [:else, 2, 1, 0, 3, 3] => 0 } } } }
    second = { script => { lines: [1],
                           branches: { branch => { [:then, 1, 2, 2, 2, 8] => 0, [:else, 2, 1, 0, 3, 3] => 4 } } } }

    expect(described_class.merge(first, second)[script][:branches][branch].values).to eq([1, 4])
  end

  # A real script process, started with a run's folder named, writes its
  # counts into that folder and no other.
  it 'has a script process write its counts into the folder it is given' do
    preload = Rails.root.join('spec/bin/preload/child_coverage.rb').to_s
    bin_script = Rails.root.join('bin/rake').to_s
    run = lambda do |dir|
      Open3.capture2e({ 'CHILD_COVERAGE_DIR' => dir, 'RUBYOPT' => "#{ENV.fetch('RUBYOPT', nil)} -r#{preload}" },
                      bin_script, '--version')
    end
    earlier = described_class.start_run(base)
    run.call(earlier)
    now = described_class.start_run(base)

    expect(described_class.read(now)).to eq({})
    run.call(now)
    expect(described_class.read(now).keys).to eq([bin_script])
    expect(described_class.read(earlier).keys).to eq([bin_script])
  end

  it "adds this run's counts to Coverage.result in the process that started the run, then removes the folder" do
    coverage = Class.new { def result = { 'app.rb' => { lines: [1] } } }.new
    coverage.singleton_class.prepend(ChildCoverage::AddRun)
    now = described_class.start_run(base)
    write_counts(now, [1, 0, nil])

    expect(coverage.result).to eq('app.rb' => { lines: [1] }, script => { lines: [1, 0, nil] })
    expect(File).not_to exist(now)
  end

  it 'leaves Coverage.result alone in a process forked from that one' do
    coverage = Class.new { def result = { 'app.rb' => { lines: [1] } } }.new
    coverage.singleton_class.prepend(ChildCoverage::AddRun)
    now = described_class.start_run(base)
    write_counts(now, [1])
    ENV['CHILD_COVERAGE_RUNNER'] = (Process.pid + 1).to_s

    expect(coverage.result).to eq('app.rb' => { lines: [1] })
    expect(File).to exist(now)
  end
end
