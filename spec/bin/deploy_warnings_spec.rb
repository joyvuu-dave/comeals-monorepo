# frozen_string_literal: true

require 'rails_helper'
require 'open3'
require 'tmpdir'

# bin/lib/deploy-warnings: the "Warnings seen during this deploy" section
# bin/deploy prints at the end. It finds the warning lines in the deploy's
# output and in the app log lines bin/deploy read, groups repeats, and
# compares them with docs/deploy-known-warnings.txt.
RSpec.describe 'bin/lib/deploy-warnings' do
  let(:dir) { Dir.mktmpdir('deploy-warnings') }
  let(:script) { Rails.root.join('bin/lib/deploy-warnings').to_s }
  let(:known_list) { Rails.root.join('docs/deploy-known-warnings.txt').to_s }

  after { FileUtils.remove_entry(dir) }

  def write(name, text)
    File.join(dir, name).tap { File.write(it, text) }
  end

  # Runs the script with the deploy log text, and the app log lines on
  # standard input. Returns the output without colors, and the colored
  # output.
  def report(log, app: 'comeals-monorepo', app_logs: '', known: known_list)
    out, status = Open3.capture2e('python3', script, app, known, write('deploy.log', log), '-', stdin_data: app_logs)
    expect(status.exitstatus).to eq(0)
    [out.gsub(/\e\[[0-9;]*m/, ''), out]
  end

  it 'says so when there is no warning line' do
    text, = report("==> Pushing\n    ✓ Code pushed\n")

    expect(text).to eq("    No warning lines.\n")
  end

  it 'finds each kind of warning line, in any case' do
    log = <<~LOG
      remote: ###### WARNING:
      remote:
      remote:        The buildpack says why.
      W, [2026-10-22T14:14:08.923216 #19]  WARN -- Something: slow
      npm warn: old lockfile
      DEPRECATION WARNING: foo is deprecated
      Deprecated: bar
      a plain line
    LOG

    text, = report(log)

    expect(text).to include('NEW: ###### WARNING: The buildpack says why.', 'NEW: WARN -- Something: slow',
                            'NEW: npm warn: old lockfile',
                            'NEW: DEPRECATION WARNING: foo is deprecated', 'NEW: Deprecated: bar',
                            '5 new, 0 known')
    expect(text).not_to include('a plain line')
  end

  # A Heroku buildpack prints "###### WARNING:" on a line of its own and
  # says what is wrong on the next line that is not blank.
  it 'adds the next line that is not blank to a buildpack warning' do
    text, = report("remote: ###### WARNING:\nremote:\nremote:        Read this.\n")

    expect(text).to include('NEW: ###### WARNING: Read this.')
  end

  it 'prints new warnings in red' do
    _, colored = report("WARNING: something new\n")

    expect(colored).to include("\e[0;31m    NEW: WARNING: something new\e[0m")
  end

  # The same warning from two dynos, or on two runs of the same task, is
  # one line with a count. The Ruby logger's time and process number and
  # Heroku's log prefix are not part of the warning.
  it 'groups repeated warnings and counts them' do
    log = <<~LOG
      W, [2026-10-22T14:14:08.923216 #19]  WARN -- Thing: broke
      W, [2026-10-22T15:33:11.331225 #18]  WARN -- Thing: broke
      2026-10-24T12:00:01.000000+00:00 app[web.1]: W, [2026-10-24T12:00:01.000000 #2]  WARN -- Thing: broke
    LOG

    text, = report(log)

    expect(text).to include('NEW: WARN -- Thing: broke (seen 3 times)', '1 new, 0 known')
  end

  describe 'docs/deploy-known-warnings.txt' do
    let(:skylight) do
      'W, [2026-10-22T14:14:08.923216 #19]  WARN -- Skylight: Unable to start Instrumenter due to a ' \
        "configuration error: authentication token required\n"
    end
    let(:bugsnag) do
      'W, [2026-10-22T14:14:08.932111 #19]  WARN -- [Bugsnag]: No valid API key has been set, notifications ' \
        "will not be sent\n"
    end
    let(:backup_note) { " ›   Warning: Logical backups of large databases are likely to fail.\n" }

    it 'knows the staging warnings on staging' do
      text, = report(skylight + bugsnag, app: 'comeals-staging')

      expect(text).to include('known (staging has no Skylight', 'known (staging has no Bugsnag', '0 new, 2 known')
    end

    it 'shows the staging warnings as new on production, where the keys must work' do
      text, = report(skylight + bugsnag)

      expect(text).to include('NEW: WARN -- Skylight', 'NEW: WARN -- [Bugsnag]', '2 new, 0 known')
    end

    it 'knows the backup note on both apps' do
      expect(report(backup_note).first).to include('known (', '0 new, 1 known')
      expect(report(backup_note, app: 'comeals-staging').first).to include('0 new, 1 known')
    end

    # Being fixed on its own branch. Until then it must show, so nobody
    # forgets it.
    it 'does not know the Ruby buildpack bin/bundle warning' do
      text, = report("remote: ###### WARNING:\nremote:        Your app's bin/bundle is not the one Bundler made\n")

      expect(text).to include("NEW: ###### WARNING: Your app's bin/bundle is not the one Bundler made")
      expect(File.read(known_list)).not_to include('bin/bundle')
    end
  end

  it 'reads fixed text and regular expressions, and each app name' do
    known = write('known.txt', <<~LIST)
      # A comment, then a blank line.

      fixed: Exact (text)
      app: both
      why: one

      regex: Pat+ern \\d+
      app: production
      why: two

      fixed: Only staging
      app: staging
      why: three
    LIST

    text, = report("WARNING Exact (text)\nWARNING Patttern 42\nWARNING Only staging\n", known:)

    expect(text).to include('known (one): WARNING Exact (text)', 'known (two): WARNING Patttern 42',
                            'NEW: WARNING Only staging', '1 new, 2 known')
  end

  it 'shortens a long known warning' do
    known = write('known.txt', "fixed: long\napp: both\nwhy: ok\n")

    text, = report("WARNING long #{'x' * 200}\n", known:)

    line = text.lines.find { it.include?('known (ok)') }
    expect(line.chomp.length).to be <= 130
    expect(line).to end_with("…\n")
  end

  it 'shows every warning as new, and says why, when the list cannot be read' do
    known = write('known.txt', "fixed: no app or reason\n")

    text, = report("WARNING Exact\n", known:)

    expect(text).to include('Could not read', 'entry 1 has no app:', 'NEW: WARNING Exact')
  end

  it 'refuses an entry with an unknown app or an unknown field' do
    expect(report("WARNING x\n", known: write('a.txt', "fixed: x\napp: prod\nwhy: y\n")).first)
      .to include('entry 1: app must be production, staging or both')
    expect(report("WARNING x\n", known: write('b.txt', "fixd: x\napp: both\nwhy: y\n")).first)
      .to include('line 1: unknown field "fixd"')
  end

  # bin/deploy prints the app log lines it found in its log check, and it
  # passes all of them on standard input too. A line is counted once.
  it 'reads the app log lines and does not count the log check section of the deploy log twice' do
    log = <<~LOG
      \e[1m==> Checking post-deploy logs\e[0m
          ⚠ Issues found in logs:
            2026-10-24T12:00:01.000000+00:00 app[web.1]: WARN -- once
      \e[1m==> Health check\e[0m
      WARNING after the section
    LOG

    text, = report(log, app_logs: "2026-10-24T12:00:01.000000+00:00 app[web.1]: WARN -- once\n")

    expect(text).to include('NEW: WARN -- once', 'NEW: WARNING after the section', '2 new, 0 known')
    expect(text).not_to include('seen 2 times')
  end
end
