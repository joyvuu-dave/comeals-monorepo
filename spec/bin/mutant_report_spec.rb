# frozen_string_literal: true

require 'rails_helper'
require 'open3'

# bin/mutant-report adds up the pieces of a Mutant workflow run
# (.github/workflows/mutant.yml) from the session file each piece left,
# and checks every survivor against the list of accepted survivors.
RSpec.describe 'bin/mutant-report' do
  let(:script) { Rails.root.join('bin/mutant-report').to_s }
  let(:dir) { Dir.mktmpdir }
  let(:list) { File.join(dir, 'accepted') }
  let(:same_diff) do
    <<~DIFF
      @@ -1,3 +1,3 @@
       def same?(left, right)
      -  left.to_s.casecmp?(right.to_s)
      +  left.to_s.casecmp?(right.to_str)
       end
    DIFF
  end
  let(:last_word_diff) do
    <<~DIFF
      @@ -1,8 +1,6 @@
       def last_word(name)
         words = name.split
         if words.length > 1
           words.last
      -  else
      -    nil
         end
       end
    DIFF
  end
  let(:mutations) do
    [{ subject: 'ResidentNameShortener#same?', path: 'app/services/resident_name_shortener.rb:76',
       diff: same_diff, ended: :alive },
     { subject: 'ResidentNameShortener#same?', diff: '@@ x', ended: :killed },
     { subject: 'ResidentNameShortener#same?', diff: '@@ neutral', ended: :neutral_ok },
     { subject: 'ResidentNameShortener#last_word', path: 'app/services/resident_name_shortener.rb:69',
       diff: last_word_diff, ended: :alive }]
  end

  after { FileUtils.remove_entry(dir) }

  def piece(name, subjects:, mutations: nil, runtime: 120.0)
    path = File.join(dir, 'pieces', name)
    FileUtils.mkdir_p(path)
    File.write(File.join(path, 'subjects.txt'), "#{subjects.join("\n")}\n")
    write_mutant_session(path, mutations, runtime: runtime) if mutations
  end

  def accept(*entries)
    write_accepted(list, entries)
  end

  def entry(subject, diff, **more)
    { 'subject' => subject, 'kind' => 'same-answer', 'why' => 'A reason.', 'diff' => diff }.merge(more)
  end

  def run_report(*flags, status: 0)
    out, result = run_ruby_script(script, *flags, File.join(dir, 'pieces'), File.join(dir, 'report.md'),
                                  env: { 'MUTANT_ACCEPTED_SURVIVORS' => list })
    expect(result.exitstatus).to eq(status), out
    expect(File.read(File.join(dir, 'report.md'))).to eq(out)
    out
  end

  it 'adds up the totals, lists each piece, and names a piece that did not finish' do
    piece('mutant-piece-0', subjects: %w[ResidentNameShortener#same? ResidentNameShortener#last_word],
                            mutations: mutations, runtime: 95.0)
    piece('mutant-piece-1', subjects: %w[Settlement#settle!])

    out = run_report(status: 1)

    expect(out).to include('4 mutations, 2 killed, 2 alive, 0 timed out: 50.00% killed.')
    expect(out).to include('Did not finish, so their subjects have no result: mutant-piece-1.')
    expect(out).to include('| mutant-piece-0 | 2 | 4 | 2 | 2 min |')
    expect(out).to include('| mutant-piece-1 | 1 | did not finish |  |  |')
  end

  it 'lists each survivor not on the list as an entry to fill in, in file order, and fails' do
    piece('mutant-piece-0', subjects: %w[ResidentNameShortener#same?], mutations: mutations)

    out = run_report(status: 1)

    expect(out).to include('## Survivors not on the list (2)')
    expect(out).to include('### ResidentNameShortener#same?, app/services/resident_name_shortener.rb:76: lived',
                           'For config/mutant/accepted_survivors/resident_name_shortener.yml:')
    expect(out).to include("```yaml\n- subject: ResidentNameShortener#same?\n  kind: same-answer\n  why: \"\"\n  " \
                           "diff: |\n    @@ -1,3 +1,3 @@\n     def same?(left, right)\n    " \
                           '-  left.to_s.casecmp?(right.to_s)')
    expect(out.index('#last_word,')).to be < out.index('#same?,')
  end

  it 'passes when every survivor is on the list, whatever spaces end its lines' do
    accept(entry('ResidentNameShortener#same?', same_diff),
           entry('ResidentNameShortener#last_word', last_word_diff.gsub(/^ $/, '').gsub("\n", "  \n")))
    piece('mutant-piece-0', subjects: %w[ResidentNameShortener#same?], mutations: mutations)

    out = run_report

    expect(out).to include("## Survivors not on the list (0)\n\nNone.")
    expect(out).to include('Accepted survivors: 2')
    expect(out).not_to include('no longer survive')
  end

  it 'fails on an entry whose mutation is killed now, and on a full run, on one whose subject did not run' do
    accept(entry('ResidentNameShortener#same?', same_diff), entry('ResidentNameShortener#last_word', last_word_diff),
           entry('ResidentNameShortener#same?', "@@ x\n"), entry('Gone#method', "@@ gone\n", 'why' => 'Gone now.'))
    piece('mutant-piece-0', subjects: %w[ResidentNameShortener#same?], mutations: mutations)

    expect(run_report(status: 1)).to include('## Entries that no longer survive (1)', "```diff\n@@ x\n```")
    expect(run_report('--full', status: 1))
      .to include('## Entries that no longer survive (2)', '- Gone#method: Gone now.')
  end

  it 'does not call an entry gone when the piece that had its subject did not finish' do
    accept(entry('ResidentNameShortener#same?', same_diff), entry('ResidentNameShortener#last_word', last_word_diff),
           entry('Settlement#settle!', "@@ y\n"))
    piece('mutant-piece-0', subjects: %w[ResidentNameShortener#same?], mutations: mutations)
    piece('mutant-piece-1', subjects: %w[Settlement#settle!])

    out = run_report('--full', status: 1)

    expect(out).not_to include('no longer survive')
    expect(out).to include('Did not finish')
  end

  it 'reads the run as Linux: a Linux-only entry that is killed is stale there' do
    accept(entry('ResidentNameShortener#same?', same_diff), entry('ResidentNameShortener#last_word', last_word_diff),
           entry('ResidentNameShortener#same?', "@@ x\n", 'only_on' => 'linux'))
    piece('mutant-piece-0', subjects: %w[ResidentNameShortener#same?], mutations: mutations)

    expect(run_report(status: 1)).to include('## Entries that no longer survive (1)')
  end

  it 'names a timeout, a process that ended with an error, and examples that fail on the code as written' do
    accept(entry('Foo#neutral', "@@ n\n"))
    piece('mutant-piece-0', subjects: %w[Foo#bar],
                            mutations: [{ subject: 'Foo#bar', diff: "@@ t\n", ended: :timeout },
                                        { subject: 'Foo#baz', diff: "@@ a\n", ended: :abort },
                                        { subject: 'Foo#neutral', diff: "@@ n\n", ended: :neutral_failed }])

    out = run_report(status: 1)

    expect(out).to include('1 timed out')
    expect(out).to include('### Foo#bar, app/services/foo.rb:10: timed out', 'kind: never-ends')
    expect(out).to include('### Foo#baz, app/services/foo.rb:10: its process ended with an error')
    expect(out).to include('### Foo#neutral, app/services/foo.rb:10: the examples fail on the code as written')
    expect(out).to include('Accepted survivors: 0')
  end

  it 'names each piece the run started that left nothing, when given the number of pieces' do
    accept(entry('ResidentNameShortener#same?', same_diff), entry('ResidentNameShortener#last_word', last_word_diff))
    piece('mutant-piece-0', subjects: %w[ResidentNameShortener#same?], mutations: mutations)
    piece('mutant-piece-2', subjects: %w[Settlement#settle!], mutations: [])

    out = run_report('--pieces', '4', status: 1)

    expect(out).to include('Left nothing, so their subjects have no result: mutant-piece-1, mutant-piece-3.')
    expect(out).to include('| mutant-piece-1 |  | left nothing |  |  |')
    expect(out).not_to include('Did not finish')
  end

  it 'refuses a number of pieces that is not a whole number' do
    out, status = run_ruby_script(script, '--pieces', 'four', 'pieces', 'report.md')

    expect(status.exitstatus).to eq(2)
    expect(out).to include('Usage: bin/mutant-report')
  end

  it 'refuses to run without a directory and a report file' do
    out, status = run_ruby_script(script, 'only-one')

    expect(status.exitstatus).to eq(2)
    expect(out).to include('Usage: bin/mutant-report')
  end

  it 'counts 0% killed when no piece ran, and fails' do
    FileUtils.mkdir_p(File.join(dir, 'pieces', 'mutant-piece-0'))

    out = run_report(status: 1)

    expect(out).to include('0 mutations, 0 killed, 0 alive, 0 timed out: 0.00% killed.')
    expect(out).to include('| mutant-piece-0 | 0 | did not finish |  |  |')
  end
end
