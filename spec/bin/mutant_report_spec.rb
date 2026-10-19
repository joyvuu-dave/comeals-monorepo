# frozen_string_literal: true

require 'rails_helper'
require 'open3'

# bin/mutant-report adds up the pieces of a Mutant workflow run
# (.github/workflows/mutant.yml). The log here is the real output of a
# run on two ResidentNameShortener methods, trimmed to its survivors and
# its totals.
RSpec.describe 'bin/mutant-report' do
  let(:script) { Rails.root.join('bin/mutant-report').to_s }
  let(:dir) { Dir.mktmpdir }
  let(:log) do
    <<~LOG
      ResidentNameShortener#same?:/home/runner/work/comeals-monorepo/comeals-monorepo/app/services/resident_name_shortener.rb:76
      tests: 30, runtime: 71.09s, killtime: 67.54s
      evil:ResidentNameShortener#same?:/home/runner/work/comeals-monorepo/comeals-monorepo/app/services/resident_name_shortener.rb:76:43c33
      -----------------------
      @@ -1,3 +1,3 @@
       def same?(left, right)
      -  left.to_s.casecmp?(right.to_s)
      +  left.to_s.casecmp?(right.to_str)
       end
      -----------------------
      (1 more alive mutation(s), use `mutant session subject ResidentNameShortener#same?` to see all details)
      ResidentNameShortener#last_word:/home/runner/work/comeals-monorepo/comeals-monorepo/app/services/resident_name_shortener.rb:69
      tests: 30, runtime: 92.57s, killtime: 86.26s
      evil:ResidentNameShortener#last_word:/home/runner/work/comeals-monorepo/comeals-monorepo/app/services/resident_name_shortener.rb:69:4e5c4
      -----------------------
      @@ -1,8 +1,6 @@
       def last_word(name)
         words = name.split
         if words.length > 1
           words.last
      -  else
      -    nil
         end
       end
      -----------------------
      Mutant environment:
      Subjects:        2
      Mutations:       51
      Results:         51
      Kills:           48
      Alive:           3
      Timeouts:        0
      Runtime:         83.03s
      Coverage:        94.11%
    LOG
  end

  after { FileUtils.remove_entry(dir) }

  def piece(name, subjects:, log: nil)
    path = File.join(dir, 'pieces', name)
    FileUtils.mkdir_p(path)
    File.write(File.join(path, 'subjects.txt'), "#{subjects.join("\n")}\n")
    File.write(File.join(path, 'mutant.log'), log) if log
  end

  def run_report
    out, status = run_ruby_script(script, File.join(dir, 'pieces'), File.join(dir, 'report.md'))
    expect(status.exitstatus).to eq(0), out
    expect(File.read(File.join(dir, 'report.md'))).to eq(out)
    out
  end

  it 'adds up the totals, lists each piece, and names a piece that stopped before mutating' do
    piece('mutant-piece-0', subjects: %w[ResidentNameShortener#same? ResidentNameShortener#last_word], log: log)
    piece('mutant-piece-1', subjects: %w[Settlement#settle!])

    out = run_report

    expect(out).to include('51 mutations, 48 killed, 3 alive, 0 timed out: 94.12% killed.')
    expect(out).to include('Stopped before mutating: mutant-piece-1.')
    expect(out).to include('| mutant-piece-0 | 2 | 51 | 3 | 1 min |')
    expect(out).to include('| mutant-piece-1 | 1 | stopped |  |  |')
  end

  it 'lists each survivor with how many mutations lived, where, and the first change' do
    piece('mutant-piece-0', subjects: %w[ResidentNameShortener#same?], log: log)

    out = run_report

    expect(out).to include('## Survivors (2 subjects)')
    expect(out).to include('### ResidentNameShortener#same? (2 alive), app/services/resident_name_shortener.rb:76')
    expect(out).to include('### ResidentNameShortener#last_word (1 alive), app/services/resident_name_shortener.rb:69')
    expect(out).to include("```diff\n@@ -1,3 +1,3 @@\n def same?(left, right)\n-  left.to_s.casecmp?(right.to_s)")
    expect(out.index('#last_word')).to be < out.index('#same?')
  end

  # #181: the workflow writes mutant's stderr into the same log, and once
  # its last line landed right after an id, with no line break.
  it 'reads a survivor whose evil: line has other output after its id' do
    joined = log.sub('resident_name_shortener.rb:76:43c33',
                     'resident_name_shortener.rb:76:43c33Uncovered mutations detected, exiting nonzero!')
    piece('mutant-piece-0', subjects: %w[ResidentNameShortener#same?], log: joined)

    out = run_report

    expect(out).to include('## Survivors (2 subjects)')
    expect(out).to include('### ResidentNameShortener#same? (2 alive), app/services/resident_name_shortener.rb:76')
  end

  it 'names each piece the run started that left nothing, when given the number of pieces' do
    piece('mutant-piece-0', subjects: %w[ResidentNameShortener#same?], log: log)
    piece('mutant-piece-2', subjects: %w[Settlement#settle!], log: log)

    out, status = run_ruby_script(script, File.join(dir, 'pieces'), File.join(dir, 'report.md'), '4')

    expect(status.exitstatus).to eq(0), out
    expect(out).to include('Left nothing, so their subjects have no result: mutant-piece-1, mutant-piece-3.')
    expect(out).to include('| mutant-piece-1 |  | left nothing |  |  |')
    expect(out).not_to include('Stopped before mutating')
  end

  it 'refuses a number of pieces that is not a whole number' do
    out, status = run_ruby_script(script, 'pieces', 'report.md', 'four')

    expect(status.exitstatus).to eq(2)
    expect(out).to include('Usage: bin/mutant-report')
  end

  it 'refuses to run without a directory and a report file' do
    out, status = run_ruby_script(script, 'only-one')

    expect(status.exitstatus).to eq(2)
    expect(out).to include('Usage: bin/mutant-report')
  end

  it 'counts 0% killed, and no subjects, when no piece ran' do
    FileUtils.mkdir_p(File.join(dir, 'pieces', 'mutant-piece-0'))

    out = run_report

    expect(out).to include('0 mutations, 0 killed, 0 alive, 0 timed out: 0.00% killed.')
    expect(out).to include('| mutant-piece-0 | 0 | stopped |  |  |')
    expect(out).to include('## Survivors (0 subjects)')
  end

  # A log cut off just after a survivor's evil: line, as when the machine
  # running the piece was stopped.
  it 'lists a survivor whose change the log does not show' do
    cut = log[0...log.index('-----------------------')]
    piece('mutant-piece-0', subjects: %w[ResidentNameShortener#same?], log: cut)

    out = run_report

    expect(out).to include("### ResidentNameShortener#same? (1 alive), app/services/resident_name_shortener.rb:76\n")
    expect(out).not_to include('```diff')
  end
end
