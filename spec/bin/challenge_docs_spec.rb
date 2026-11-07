# frozen_string_literal: true

require 'rails_helper'
require 'tmpdir'
require Rails.root.join('bin/lib/challenge_docs').to_s

# docs/challenges/ and its rules (docs/challenges/README.md). The first
# example runs every rule on the real folder, so bin/check and CI fail
# when a challenge doc breaks one. The rest show each rule on a folder
# made for the example.
RSpec.describe 'bin/challenges' do
  let(:today) { Date.new(2026, 11, 7) }
  let(:root) { Dir.mktmpdir }
  let(:dir) { File.join(root, 'docs/challenges') }
  let(:readme) { "# Challenges\n\n#{ChallengeDocs::Index::START}\n#{ChallengeDocs::Index::FINISH}\n" }

  after { FileUtils.remove_entry(root) }

  def front(**changes)
    values = { id: 1, title: 'A thing', area: 'time', status: 'open', opened: '2026-11-01',
               reviewed: '2026-11-02', watches: '[]' }.merge(changes)
    "---\n#{values.map { |key, value| "#{key}: #{value}\n" }.join}---\n"
  end

  def body(title: 'A thing', sections: nil)
    sections ||= {
      'The challenge' => 'Text.', 'The case that breaks it' => 'Text.', 'Where we stand' => 'Text.',
      'Options' => 'Text.', 'History' => '- 2026-11-01: Opened.'
    }
    "\n# #{title}\n\n#{sections.map { |name, text| "## #{name}\n\n#{text}\n" }.join("\n")}"
  end

  def write(name, text)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, name), text)
  end

  def write_root(path, text = "x\n")
    FileUtils.mkdir_p(File.dirname(File.join(root, path)))
    File.write(File.join(root, path), text)
  end

  def problems = ChallengeDocs.problems(dir, root: root, today: today)

  def run_cli(*argv)
    out = StringIO.new
    status = ChallengeDocs::CLI.run(argv, dir: dir, root: root, today: today, out: out)
    [status, out.string]
  end

  # A folder with one good challenge, its index written.
  def good_folder
    write('README.md', readme)
    write('0001-a-thing.md', front + body)
    ChallengeDocs::Index.write(dir)
  end

  it 'finds no problem in the real docs/challenges folder' do
    real = Rails.root.join('docs/challenges').to_s
    expect(ChallengeDocs.problems(real, root: Rails.root.to_s, today: Date.current)).to eq([])
  end

  it 'finds no problem in a good folder' do
    good_folder
    expect(problems).to eq([])
  end

  describe 'reading a file' do
    before { write('README.md', readme) }

    it 'needs front matter between two --- lines' do
      write('0001-a-thing.md', body)
      expect(problems).to include('0001-a-thing.md has no front matter between two --- lines at the top')
    end

    it 'needs the front matter to be a list of keys' do
      write('0001-a-thing.md', "---\n- one\n---\n#{body}")
      expect(problems).to include('0001-a-thing.md has front matter that is not a list of keys')
    end

    it 'needs the front matter to be YAML' do
      write('0001-a-thing.md', "---\nid: [1\n---\n#{body}")
      expect(problems.first).to start_with('0001-a-thing.md has front matter that is not YAML')
    end
  end

  describe 'the front matter' do
    before { write('README.md', readme) }

    it 'names a missing key and a key it does not know' do
      write('0001-a-thing.md', front(watches: nil, owner: 'me').sub("watches: \n", '') + body)
      expect(problems).to include('0001-a-thing.md is missing watches in its front matter',
                                  '0001-a-thing.md has owner in its front matter, which is not a known key')
    end

    it 'needs a numbered file name, and an id that matches it' do
      write('a-thing.md', front + body)
      write('0002-other.md', front(id: 3) + body)
      expect(problems).to include('a-thing.md must be named like 0012-short-name.md',
                                  '0002-other.md has id 3, but its file name says 2')
    end

    it 'needs a known area and status, dates, and a list of watched files' do
      write('0001-a-thing.md', front(area: 'misc', status: 'maybe', watches: 'app/x.rb') + body)
      expect(problems).to include(
        start_with('0001-a-thing.md has area "misc"'), start_with('0001-a-thing.md has status "maybe"'),
        '0001-a-thing.md must list its watched files under watches (an empty list is [])'
      )
    end

    it 'needs the watched files as text' do
      write('0001-a-thing.md', front(watches: '[1]') + body)
      expect(problems).to include('0001-a-thing.md must list its watched files under watches (an empty list is [])')
    end

    it 'needs real dates, reviewed no earlier than opened' do
      write('0001-a-thing.md', front(opened: 'someday') + body)
      write('0002-other.md', front(id: 2, reviewed: '2026-10-01') + body)
      expect(problems).to include('0001-a-thing.md must give opened as a date like 2026-11-07',
                                  '0002-other.md was reviewed before it was opened')
    end
  end

  describe 'the sections' do
    before { write('README.md', readme) }

    it 'needs the title as the first heading' do
      write('0001-a-thing.md', front + body(title: 'Another thing'))
      expect(problems).to include('0001-a-thing.md must start with the heading "# A thing"')
    end

    it 'names an unknown section, a missing one, and the wrong order' do
      sections = { 'Options' => 'Text.', 'The challenge' => 'Text.', 'Notes' => 'Text.',
                   'History' => '- 2026-11-01: Opened.' }
      write('0001-a-thing.md', front + body(sections: sections))
      expect(problems).to include(
        start_with('0001-a-thing.md has a section "Notes"'),
        '0001-a-thing.md has no "Where we stand" section',
        start_with('0001-a-thing.md has its sections out of order')
      )
    end

    it 'needs a Decision once something was decided' do
      write('0001-a-thing.md', front(status: 'done') + body)
      expect(problems).to include(start_with('0001-a-thing.md is done, so it needs a "Decision" section'))
    end

    it 'takes a decided challenge that has its Decision' do
      sections = { 'The challenge' => 'Text.', 'The case that breaks it' => 'Text.', 'Where we stand' => 'Text.',
                   'Options' => 'Text.', 'Decision' => 'We did it.', 'History' => '- 2026-11-01: Opened.' }
      write('0001-a-thing.md', front(status: 'declined') + body(sections: sections))
      ChallengeDocs::Index.write(dir)
      expect(problems).to eq([])
    end

    it 'needs dated History lines, starting on the day it was opened' do
      sections = { 'The challenge' => 'Text.', 'The case that breaks it' => 'Text.', 'Where we stand' => 'Text.',
                   'Options' => 'Text.', 'History' => "- 2026-11-03: Changed.\nOpened on Monday." }
      write('0001-a-thing.md', front + body(sections: sections))
      expect(problems).to include(
        '0001-a-thing.md has a History line that does not start with "- YYYY-MM-DD: ": Opened on Monday.',
        '0001-a-thing.md must start its History with the day it was opened, 2026-11-01'
      )
    end
  end

  describe 'the text' do
    before { write('README.md', readme) }

    def with(section, text)
      sections = { 'The challenge' => 'Text.', 'The case that breaks it' => 'Text.', 'Where we stand' => 'Text.',
                   'Options' => 'Text.', section => text, 'History' => '- 2026-11-01: Opened.' }
      write('0001-a-thing.md', front + body(sections: sections))
    end

    it 'refuses words that stop being true by themselves' do
      with('Where we stand', 'This is currently true.')
      expect(problems).to include('0001-a-thing.md uses the word "currently"; write the date or the plain fact instead')
    end

    it 'needs every repo path it names to exist, with a line number or anchor cut off' do
      write_root('app/real.rb')
      with('Where we stand', 'See `app/real.rb:12`, `docs/gone.md#part`, and `app/models/*.rb`.')
      expect(problems).to include('0001-a-thing.md names docs/gone.md, which does not exist')
      expect(problems.join).not_to include('real.rb')
    end

    it 'needs every relative link to exist, and leaves web links alone' do
      write('0002-other.md', front(id: 2) + body)
      with('Options', '[a](0002-other.md#x) [b](missing.md) [c](https://example.com) [d](#top) [e](mailto:a@b.c)')
      expect(problems).to include('0001-a-thing.md links to missing.md, which does not exist')
      expect(problems.join).not_to include('example.com')
    end

    it 'needs each outside fact to say when and where it was checked, and fails one older than a year' do
      with('Outside facts', "- Fresh. (checked 2026-06-01: a manual)\n- Old. (checked 2025-11-01: a manual)\n- Bare.")
      expect(problems).to include(
        '0001-a-thing.md has an outside fact with no "(checked YYYY-MM-DD: source)": - Bare.',
        '0001-a-thing.md has an outside fact last checked 2025-11-01; check it again and change the date'
      )
      expect(problems.join).not_to include('2026-06-01')
    end
  end

  describe 'the folder' do
    before { write('README.md', readme) }

    it 'needs one challenge per id, numbered with no gap' do
      write('0001-a-thing.md', front + body)
      write('0001-again.md', front + body)
      write('0003-later.md', front(id: 3) + body)
      expect(problems).to include('More than one challenge has id 1',
                                  'The challenge ids must run 1, 2, 3 ... with no gap; they are 1, 1, 3')
    end

    it 'needs the index to match the files' do
      write('0001-a-thing.md', front + body)
      expect(problems).to include(ChallengeDocs::Index::OUT_OF_DATE)
    end

    it 'needs the index markers' do
      write('README.md', "# Challenges\n")
      write('0001-a-thing.md', front + body)
      expect(problems).to include(start_with('README.md has no index markers'))
      write('README.md', "#{ChallengeDocs::Index::START}\n")
      expect(problems).to include(start_with('README.md has no index markers'))
    end
  end

  describe 'watched files' do
    before do
      write('README.md', readme)
      write_root('app/x.rb')
      write('0001-a-thing.md', front(watches: '[app/x.rb]') + body)
      ChallengeDocs::Index.write(dir)
    end

    it 'needs a challenge that watches a file to be reviewed once' do
      expect(problems).to eq(
        ['Challenge 1 watches app/x.rb, but was not reviewed since; run bin/challenges reviewed 1']
      )
    end

    it 'fails when a watched file changes, until the challenge is reviewed again' do
      ChallengeDocs::Watches.mark_reviewed(dir, 1, root: root, today: today)
      expect(problems).to eq([])
      write_root('app/x.rb', "changed\n")
      expect(problems).to eq([
                               'app/x.rb changed since challenge 1 was reviewed. Read what that doc says about it, ' \
                               'fix the doc, then run bin/challenges reviewed 1'
                             ])
      ChallengeDocs::Watches.mark_reviewed(dir, 1, root: root, today: today)
      expect(problems).to eq([])
      expect(File.read(File.join(dir, '0001-a-thing.md'))).to include('reviewed: 2026-11-07')
    end

    it 'names a watched file that does not exist, and a fingerprint nobody watches' do
      write('0001-a-thing.md', front(watches: '[app/gone.rb]') + body)
      File.write(File.join(dir, 'watched.txt'), "0001 app/x.rb abc\n")
      expect(problems).to include(
        '0001-a-thing.md watches app/gone.rb, which does not exist',
        'watched.txt has app/x.rb for challenge 1, which does not watch it; run bin/challenges reviewed 1'
      )
    end

    it 'cannot review a challenge that does not exist' do
      expect(ChallengeDocs::Watches.mark_reviewed(dir, 9, root: root, today: today)).to eq('No challenge has id 9')
    end
  end

  describe 'the HTML page' do
    let(:html) { ChallengeDocs::Html }

    def stand(where, facts = nil)
      sections = { 'The challenge' => 'Text.', 'The case that breaks it' => 'Text.', 'Where we stand' => where,
                   'Options' => 'See [the other](0002-other.md) and [an ADR](../adr/0001-x.md#why).' }
      sections['Outside facts'] = facts if facts
      sections['Decision'] = 'Done.'
      sections['History'] = '- 2026-11-01: Opened.'
      sections
    end

    before do
      write('README.md', readme)
      write_root('app/x.rb')
      write_root('app/y.rb')
      write_root('docs/adr/0001-x.md')
    end

    it 'is written with the index, and fails the check when it no longer matches the files' do
      write('0001-a-thing.md', front + body)
      expect(problems).to include(html::OUT_OF_DATE)
      ChallengeDocs::Index.write(dir)
      expect(problems).to eq([])
      write('0001-a-thing.md', front(status: 'exploring') + body)
      expect(problems).to include(html::OUT_OF_DATE)
    end

    it 'shows what is left, what is finished, and what nobody has checked' do
      facts = "- One. (checked 2026-11-01: Claude's memory, not the docs)\n" \
              "- Two. (checked 2026-11-01: Claude's memory, not the docs)"
      write('0001-a-thing.md', front(status: 'done', watches: '[app/x.rb, app/y.rb]') +
                               body(sections: stand("- Not checked: one.\n- Not tried: two.", facts)))
      one_fact = "- One. (checked 2026-11-01: Claude's memory)"
      write('0002-other.md', front(id: 2, title: 'Other', area: 'money', watches: '[app/x.rb]') +
                             body(title: 'Other', sections: stand('Fine.', one_fact)))
      page = html.render(ChallengeDocs.docs(dir))
      expect(page).to include('<div class="n">1</div><div>still to do, of 2</div>',
                              '<span class="badge">2 not checked</span>',
                              '<span class="badge">2 outside facts to read</span>',
                              '<span class="badge">1 outside fact to read</span>',
                              '<summary>Watches 2 files</summary>', '<summary>Watches 1 file</summary>',
                              '<h3>The challenge</h3>', '<a href="#challenge-2">the other</a>',
                              '<a href="../adr/0001-x.md#why">an ADR</a>',
                              '<li class="area-head">money</li>', '<ul class="finished"><li>')
      expect(page).not_to include('<h2 id="the-challenge"', 'area-head">time')
    end

    it 'shows an empty folder' do
      page = html.render([])
      expect(page).to include('still to do, of 0', 'style="width: 0%"', '<li class="none">None yet.</li>')
      expect(page).not_to include('Watches')
    end
  end

  describe 'the command line' do
    it 'checks a good folder and a broken one' do
      good_folder
      expect(run_cli('check')).to eq([0, "ok: 1 challenges, no problems\n"])
      write('0002-other.md', front(id: 2) + body)
      expect(run_cli('check')).to eq([1, "#{ChallengeDocs::Index::OUT_OF_DATE}\n#{ChallengeDocs::Html::OUT_OF_DATE}\n"])
    end

    it 'writes the index' do
      write('README.md', readme)
      write('0001-a-thing.md', front + body)
      expect(run_cli('index')).to eq([0, "ok\n"])
      expect(File.read(File.join(dir, 'README.md')))
        .to include("| #   | Challenge                  | Area | Status | Reviewed   |\n" \
                    "| --- | -------------------------- | ---- | ------ | ---------- |\n" \
                    "| 1   | [A thing](0001-a-thing.md) | time | open   | 2026-11-02 |\n")
      write('README.md', "# Challenges\n")
      expect(run_cli('index').first).to eq(1)
    end

    it 'marks challenges reviewed, and refuses an id that is not a number' do
      good_folder
      expect(run_cli('reviewed', '1')).to eq([0, "ok\n"])
      expect(run_cli('reviewed', '7')).to eq([1, "No challenge has id 7\n"])
      expect(run_cli('reviewed', 'one').first).to eq(2)
      expect(run_cli('reviewed').first).to eq(2)
    end

    it 'starts a new challenge from the template, numbered after the last one' do
      good_folder
      status, output = run_cli('new', 'money', 'A new', 'thing!')
      expect(status).to eq(0)
      expect(output).to eq("#{dir}/0002-a-new-thing.md\n")
      expect(problems).to eq([])
    end

    it 'refuses a new challenge with an unknown area or no title' do
      good_folder
      areas = ChallengeDocs::AREAS.join(', ')
      expect(run_cli('new', 'misc', 'A thing')).to eq([1, "Use one of these areas: #{areas}\n"])
      expect(run_cli('new', 'money', '!!')).to eq([1, "Give the challenge a title\n"])
      expect(run_cli('new', 'money').first).to eq(2)
      expect(run_cli('anything').first).to eq(2)
    end

    it 'runs as bin/challenges on the real folder' do
      output, status = run_ruby_script(Rails.root.join('bin/challenges').to_s, 'check')
      expect([output, status.exitstatus]).to match([start_with('ok: '), 0])
    end
  end
end
