# frozen_string_literal: true

require 'rails_helper'

# BashCoverage (spec/support/bash_coverage.rb), which holds bin/deploy and
# the other bash files in BashCoverage::FILES at 100% of their lines.
RSpec.describe BashCoverage do
  let(:coverage) { described_class.new('spec/bin/deploy_spec.rb') }
  let(:output_sh) { Rails.root.join('bin/lib/output.sh').to_s }
  let(:delimiter) { Bashcov::Xtrace.delimiter }

  before { coverage.load_bashcov }

  def record(lineno, source)
    "+BASHCOV>#{delimiter}#{lineno}#{delimiter}#{source}#{delimiter}/#{delimiter}/#{delimiter}"
  end

  def trace_records(text)
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'trace')
      File.write(path, text)
      coverage.send(:trace_records, path)
    end
  end

  it 'counts the lines a run of a script ran' do
    status = coverage.run('-c', ". #{output_sh.shellescape}; red x >/dev/null")

    expect(status).to be_success
    counts = coverage.instance_variable_get(:@counts).fetch(output_sh)
    expect(counts[8]).to eq(1) # red()
    # bashcov does not count a one-line function that did not run (green()
    # here); #check! requires those lines itself.
    expect(counts[9]).to be_nil
  end

  it 'reads every record of a whole trace' do
    text = "#{record(9, output_sh)} red x\n#{record(15, output_sh)} info y\n"

    expect(trace_records(text)).to eq([[9, output_sh], [15, output_sh]])
  end

  it 'fails loudly when a record is cut' do
    text = "#{record(9, output_sh)} red x\n+BASHCOV>#{delimiter}1"

    expect { trace_records(text) }.to raise_error(BashCoverage::TraceLost, /a bash trace record is broken/)
  end

  it 'fails loudly when a record was written but cannot be read' do
    unreadable = record(15, output_sh).delete_prefix('+')
    text = "#{record(9, output_sh)} red x\n#{unreadable} info y\n"

    expect { trace_records(text) }.to raise_error(BashCoverage::TraceLost, /bash wrote 2 trace records and 1 were read/)
  end

  it 'fails when a line it holds did not run, and names the line' do
    # Every other file of the spec ran all its lines, so output.sh is the
    # only one that fails.
    counts = coverage.instance_variable_get(:@counts)
    (counts.keys - [output_sh]).each { counts[it] = Array.new(File.readlines(it).size, 1) }
    coverage.run('-c', ". #{output_sh.shellescape}; red x >/dev/null")

    expect { coverage.check! }.to raise_error(RuntimeError, %r{bin/lib/output.sh:10: green\(\)})
  end
end
