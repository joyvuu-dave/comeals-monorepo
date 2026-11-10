# frozen_string_literal: true

require 'rails_helper'

# bin/mutant-survivors checks a run on this machine (bin/mutant runs it
# after mutant) against the list of accepted survivors.
RSpec.describe 'bin/mutant-survivors' do
  let(:script) { Rails.root.join('bin/mutant-survivors').to_s }
  let(:dir) { Dir.mktmpdir }
  let(:list) { File.join(dir, 'accepted') }
  let(:env) { { 'MUTANT_ACCEPTED_SURVIVORS' => list } }
  let(:alive) { { subject: 'Foo#bar', diff: "@@ -1 +1 @@\n-a\n+b\n", ended: :alive } }

  before do
    write_accepted(list, [{ 'subject' => 'Foo#bar', 'kind' => 'same-answer', 'why' => 'A reason.',
                            'diff' => "@@ -1 +1 @@\n-a\n+b\n" },
                          { 'subject' => 'Gone#method', 'kind' => 'same-answer', 'why' => 'Gone now.',
                            'diff' => "@@ gone\n" }])
  end

  after { FileUtils.remove_entry(dir) }

  it 'passes when every survivor of the given session is on the list' do
    session = write_mutant_session(dir, [alive, { subject: 'Foo#bar', diff: '@@ k', ended: :killed }])

    out, status = run_ruby_script(script, session, env: env)

    expect(status.exitstatus).to eq(0), out
    expect(out).to include('Survivors not on the list (0)', 'Accepted survivors: 1')
  end

  it 'reads the newest session in .mutant/results when given none' do
    write_mutant_session(dir, [alive], id: 'old')
    newest = write_mutant_session(dir, [alive.merge(diff: "@@ new\n")], id: 'new')
    later = File.mtime(newest) + 60
    File.utime(later, later, newest)

    out, status = run_ruby_script(script, env: env, chdir: dir)

    expect(status.exitstatus).to eq(1)
    expect(out).to include('Survivors not on the list (1)', '@@ new')
  end

  it 'on a full run, fails on an entry whose subject did not run' do
    session = write_mutant_session(dir, [alive])

    out, status = run_ruby_script(script, '--full', session, env: env)

    expect(status.exitstatus).to eq(1)
    expect(out).to include('Entries that no longer survive (1)', '- Gone#method: Gone now.')
  end

  it 'fails when mutant left no session' do
    out, status = run_ruby_script(script, env: env, chdir: dir)

    expect(status.exitstatus).to eq(1)
    expect(out).to include('No mutant session in .mutant/results')
  end

  it 'refuses an option it does not know' do
    out, status = run_ruby_script(script, '--fast', env: env)

    expect(status.exitstatus).to eq(2)
    expect(out).to include('Usage: bin/mutant-survivors')
  end
end
