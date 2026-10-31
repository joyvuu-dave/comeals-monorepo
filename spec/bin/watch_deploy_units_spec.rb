# frozen_string_literal: true

require 'rails_helper'
require 'open3'
require 'tmpdir'
require Rails.root.join('bin/lib/deploy_watch/board').to_s
require Rails.root.join('bin/lib/deploy_watch/reads').to_s
require Rails.root.join('bin/lib/deploy_watch/report').to_s
require Rails.root.join('bin/lib/deploy_watch/schedule').to_s
require Rails.root.join('bin/lib/deploy_watch/watch').to_s

# The rules inside bin/watch-deploy, one at a time and with no waiting. The
# board takes the time as an argument, so a spec can say what each read
# answered and when. spec/bin/watch_deploy_spec.rb runs whole watches.
RSpec.describe 'bin/watch-deploy, its parts' do
  let(:start) { Time.utc(2026, 10, 30, 12, 0, 0) }
  let(:ends) { start + 1800 }
  let(:known) do
    DeployWatch::KnownWarnings.new(Rails.root.join('docs/deploy-known-warnings.txt').to_s,
                                   'comeals-monorepo')
  end
  let(:schedule) { DeployWatch::Schedule.new({ 'hourly' => '12 * * * * UTC', 'daily' => '30 22 * * * UTC' }) }
  let(:releases) do
    [{ 'version' => 619, 'status' => 'succeeded', 'description' => 'Deploy c28c3052',
       'created_at' => '2026-10-30T11:55:00Z' },
     { 'version' => 618, 'status' => 'succeeded', 'description' => 'Deploy aaaa1111',
       'created_at' => '2026-10-20T11:55:00Z' }]
  end
  let(:first_release) { { version: 619, commit: 'c28c3052aaaa', maintenance: 'off', status: 'succeeded', releases: } }
  let(:board) do
    DeployWatch::Board.new(started_at: start, ends_at: ends, known:, schedule:, first_release:, bugsnag_skipped: nil)
  end
  let(:report) do
    DeployWatch::Report.new(app: 'comeals-monorepo', board:, started_at: start, ends_at: ends,
                            color: false)
  end

  def good(data) = DeployWatch::Reads::Reading.new(true, data, nil)
  def failed(error) = DeployWatch::Reads::Reading.new(false, nil, error)
  def row(name, now = start + 60) = board.rows(now).find { it.name == name }
  def log(seconds, source, text) = "#{(start + seconds).iso8601(6)} #{source}: #{text}\n"

  def database(**facts)
    { heartbeats: { 'Supervisor' => 1, 'Dispatcher' => 2, 'Worker' => 3, 'Scheduler' => 4 }, failed_new: 0,
      failed_old: 0, failed_first: nil,
      ledger: { at: start - 60, checked: 4, mismatches: 0, error: '' }, jobs: [] }.merge(facts)
  end

  describe DeployWatch::KnownWarnings do
    # Run the real bin/lib/deploy-warnings, which bin/deploy runs, and read
    # which lines it calls known.
    def python_says_known(lines, app)
      Dir.mktmpdir do |dir|
        path = File.join(dir, 'lines')
        File.write(path, lines.join("\n"))
        list = Rails.root.join('docs/deploy-known-warnings.txt').to_s
        out, status = Open3.capture2(Rails.root.join('bin/lib/deploy-warnings').to_s, app, list, path)
        expect(status).to be_success
        out.scan('known (').size
      end
    end

    it 'gives the same answers as the reader bin/deploy uses, on both apps' do
      lines = ['WARN -- Skylight: Unable to start Instrumenter due to a configuration error: authentication ' \
               'token required',
               'WARN -- [Bugsnag]: No valid API key has been set',
               'Warning: Logical backups of large databases are likely to fail',
               'npm warn deprecated eslint@9.0.0', 'warning code=H80 from the router',
               'warning code=H27 from the router',
               'warning No route matches [GET] "/x"', 'WARN -- something else entirely']
      %w[comeals-monorepo comeals-staging].each do |app|
        reader = described_class.new(Rails.root.join('docs/deploy-known-warnings.txt').to_s, app)
        mine = lines.count { |line| reader.reason(line) }
        expect(mine).to eq(python_says_known(lines, app)), "they disagree on #{app}"
      end
    end

    it 'cleans a line the way the other reader does' do
      line = "2026-10-24T12:00:01.000000+00:00 app[web.1]: W, [2026 #19]  \e[0mWARN -- x\n"

      expect(described_class.clean(line)).to eq('WARN -- x')
    end

    it 'knows the lines the watch expects' do
      expect(known.reason('at=error code=H80 desc="Maintenance mode"')).to include('maintenance')
      expect(known.reason('sock=client at=warning code=H27 desc="Client Request Interrupted"'))
        .to include('Better Stack')
      expect(known.reason('No route matches [GET] "/wp-login.php" (404 Not Found)')).to include('scanner')
      expect(known.reason('at=error code=H12 desc="Request timeout"')).to be_nil
    end

    it 'keeps an entry for another app out' do
      expect(known.reason('[Bugsnag]: No valid API key has been set')).to be_nil
    end

    [['bad: 1', 'unknown field'], ["app: both\nwhy: x", 'entry needs'], ["fixed: x\nwhy: y", 'entry needs'],
     ["fixed: x\napp: nope\nwhy: y", 'entry needs'],
     ["regex: (\napp: both\nwhy: y", '('], ['no colon here', 'unknown field']].each do |text, message|
      it "refuses a list holding #{text.inspect}" do
        Dir.mktmpdir do |dir|
          path = File.join(dir, 'list')
          File.write(path, "# a comment\n\n#{text}\n")
          expect do
            described_class.new(path, 'comeals-monorepo')
          end.to raise_error(described_class::ListError, /#{Regexp.escape(message)}/)
        end
      end
    end

    it 'refuses a list it cannot read' do
      expect { described_class.new('/no/such/file', 'comeals-monorepo') }.to raise_error(described_class::ListError)
    end
  end

  describe DeployWatch::Schedule do
    it 'reads the real schedule, every entry of it' do
      real = described_class.from_file(Rails.root.join('config/recurring.yml').to_s)

      expect(real.unread).to eq([])
      expect(real.next_after(Time.utc(2026, 10, 30, 12, 0,
                                      0))).to eq(['clear_finished_jobs', Time.utc(2026, 10, 30, 12, 12, 0)])
      expect(real.due(Time.utc(2026, 10, 30, 15, 50, 0), Time.utc(2026, 10, 30, 16, 5, 0)))
        .to eq([['send_missed_settlement_mail', Time.utc(2026, 10, 30, 16, 0, 0)]])
    end

    it 'lists a job due across an hour, a day and its own minute, in order' do
      due = schedule.due(Time.utc(2026, 10, 30, 22, 12, 0), Time.utc(2026, 10, 30, 23, 12, 0))

      expect(due).to eq([['hourly', Time.utc(2026, 10, 30, 22, 12, 0)], ['daily', Time.utc(2026, 10, 30, 22, 30, 0)],
                         ['hourly', Time.utc(2026, 10, 30, 23, 12, 0)]])
    end

    it 'lists a form it does not read, and does not guess' do
      other = described_class.new({ 'odd' => '0 3 * * 1 UTC', 'none' => nil, 'fine' => '1 2 * * * UTC' })

      expect(other.unread).to eq(%w[odd none])
      expect(other.next_after(start)).to eq(['fine', Time.utc(2026, 10, 31, 2, 1, 0)])
    end
  end

  describe DeployWatch::LogScan do
    let(:scan) { board.log }

    it 'skips a line that does not look like a log line, or has no real time' do
      scan.add("Heroku CLI says hello\n", 1)
      scan.add("not-a-time app[web.1]: ERROR oops\n", 1)

      expect(scan.lines).to eq(0)
      expect(board.problems).to eq([])
    end

    it 'reads a line that is not valid text' do
      scan.add(log(-9, 'app[web.1]', 'old'), 1)
      scan.add(log(1, 'app[web.1]', "ERROR \xFF broke"), 1)

      expect(board.problems.first.key).to eq('ERROR')
    end

    it 'skips lines from before the watch' do
      scan.add(log(-5, 'app[web.1]', 'ERROR old'), 1)

      expect(board.problems).to eq([])
    end

    it 'counts a line once when a new stream repeats it' do
      line = log(1, 'heroku[router]', 'method=GET path="/" status=200')
      scan.add(log(-9, 'app[web.1]', 'old'), 1)
      scan.add(line, 1)
      scan.add(log(-9, 'app[web.1]', 'old'), 2)
      scan.add(line, 2)

      expect(scan.requests).to eq(1)
      expect(row('Requests').status).to eq(:ok)
    end

    it 'says lines were lost when a new stream starts after the last line seen' do
      scan.add(log(-9, 'app[web.1]', 'old'), 1)
      scan.add(log(100, 'app[web.1]', 'one'), 1)
      scan.add(log(400, 'app[web.1]', 'two'), 2)

      expect(row('Requests').status).to eq(:unknown)
      expect(row('Requests').text).to include('were lost')
      expect(row('Warnings').status).to eq(:unknown)
    end

    {
      'a router H code' => ['heroku[router]',
                            'at=error code=H12 desc="Request timeout" method=GET path="/" status=503', :requests,
                            'H12'],
      'a 5xx with no code' => ['heroku[router]', 'at=info method=GET path="/" status=500', :requests, 'status 500'],
      'an R code on a dyno' => ['heroku[web.1]', 'Error R14 (Memory quota exceeded)', :requests, 'R14'],
      'an app error' => ['app[worker.1]', 'E, [x #1] ERROR -- : NoMethodError: nope', :app_errors, 'ERROR'],
      'a warning' => ['app[web.1]', 'W, [x #1]  WARN -- : something new', :warnings, 'WARN -- : something new'],
      'a web restart' => ['heroku[web.1]', 'State changed from up to starting', :web, 'restart web.1'],
      'a worker restart' => ['heroku[worker.1]', 'Cycling', :worker, 'restart worker.1'],
      'a web crash' => ['heroku[web.1]', 'State changed from starting to crashed', :web, 'restart web.1']
    }.each do |name, (source, text, check, key)|
      it "calls #{name} a problem, with its line" do
        line = log(10, source, text)
        scan.add(line, 1)

        expect(board.problems.map { [it.check, it.key, it.first_line] }).to eq([[check, key, line.chomp]])
      end
    end

    {
      'a dyno coming up' => ['heroku[web.1]', 'State changed from starting to up'],
      'a one-off dyno ending' => ['heroku[run.1234]', 'State changed from up to complete'],
      'a line from the platform' => ['app[api]', 'ERROR in a release description'],
      'a scanner line that holds the word ERROR' => ['app[web.1]',
                                                     'INFO -- : No route matches [GET] "/ERROR" (404 Not Found)'],
      'an ordinary line' => ['app[web.1]', 'I, [x #1]  INFO -- : Started GET "/"']
    }.each do |name, (source, text)|
      it "does not call #{name} a problem" do
        scan.add(log(10, source, text), 1)

        expect(board.problems).to eq([])
      end
    end

    it 'calls a code on a router line with no status a problem' do
      scan.add(log(10, 'heroku[router]', 'at=error code=H10 desc="App crashed" method=GET path="/" status='), 1)

      expect(board.problems.map(&:key)).to eq(['H10'])
    end

    it 'shows a new warning as a warning, and counts it as a problem' do
      scan.add(log(10, 'app[web.1]', 'W, [x #1]  WARN -- : something new'), 1)

      expect(row('Warnings')).to have_attributes(status: :warn, text: '1 new · see below')
      expect(report).to be_needs_look(start + 60, false)
    end

    it 'keeps a repeat of a problem as one problem, and counts it' do
      scan.add(log(10, 'heroku[router]', 'at=info path="/" status=500'), 1)
      scan.add(log(11, 'heroku[router]', 'at=info path="/x" status=500'), 1)

      expect(board.problems.map(&:count)).to eq([2])
    end

    it 'names the last request, and who may have sent it' do
      scan.add(log(10, 'heroku[router]', 'method=GET path="/api/v1/meals" status=200'), 1)
      expect(scan.last_event).to end_with('GET /api/v1/meals 200')

      scan.add(log(11, 'heroku[router]', 'method=GET path="/api/v1/version" status=200'), 1)
      expect(scan.last_event).to end_with('GET /api/v1/version 200 (Better Stack or this watch)')
    end
  end

  describe DeployWatch::Board do
    it 'waits, and does not pass, before the first read' do
      expect(board.rows(start).map(&:status)).to all(eq(:wait))
    end

    it 'shows a failed read as could not check, then passes after a good one' do
      board.apply(:site, failed('curl /: boom'), start + 30)
      expect(row('Site').status).to eq(:unknown)
      expect(row('Site').text).to eq('could not check: curl /: boom')

      board.apply(:site, good({ '/' => '200', '/api/v1/version' => '200' }), start + 60)
      expect(row('Site').status).to eq(:ok)
      expect(row('Site').text).to eq('/  and  /api/v1/version → 200 (checked 1 time)')
    end

    it 'shows could not check when too long passed with no good read, even if the reads now work' do
      answer = { '/' => '200', '/api/v1/version' => '200' }
      board.apply(:site, good(answer), start + 30)
      board.apply(:site, good(answer), start + 400)

      expect(row('Site').status).to eq(:unknown)
      expect(row('Site').text).to include('no good read for 6 minutes')
    end

    it 'does not blame a check for the time of a gap' do
      answer = { '/' => '200', '/api/v1/version' => '200' }
      board.apply(:site, good(answer), start + 30)
      board.gap(start + 31, start + 400)
      board.apply(:site, good(answer), start + 410)

      expect(row('Site').status).to eq(:ok)
      expect(board.watched_seconds(ends)).to eq(1800 - 369)
    end

    describe 'dynos' do
      def dyno(name, type, state: 'up', version: 619, updated_at: 'a')
        { name:, type:, state:, version:, updated_at: }
      end

      it 'calls no web dyno and no worker dyno a problem' do
        board.apply(:dynos, good([]), start + 1)

        expect(board.problems.map(&:text)).to eq(['No web dyno is running', 'No worker dyno is running'])
      end

      it 'calls a dyno that is not up, or on another release, a problem' do
        board.apply(:dynos, good([dyno('web.1', 'web', state: 'starting'), dyno('worker.1', 'worker', version: 618)]),
                    start + 1)

        expect(board.problems.map(&:text)).to eq(['web.1 was starting', 'worker.1 runs v618'])
      end

      it 'calls a change in a dyno a restart, but not its first read' do
        board.apply(:dynos, good([dyno('web.1', 'web'), dyno('worker.1', 'worker')]), start + 1)
        expect(board.problems).to eq([])

        board.apply(:dynos, good([dyno('web.1', 'web', updated_at: 'b'), dyno('worker.1', 'worker')]), start + 61)
        expect(board.problems.map(&:text)).to eq(['web.1 restarted'])
      end

      it 'shows two dyno problems as the first and a count' do
        board.apply(:dynos, good([dyno('web.1', 'web', state: 'crashed', version: 618), dyno('worker.1', 'worker')]),
                    start + 1)

        expect(row('Web').text).to eq('web.1 was crashed · and 1 more')
      end
    end

    describe 'the database read' do
      it 'calls a stale or missing heartbeat a problem' do
        board.apply(:database, good(database(heartbeats: { 'Supervisor' => 500, 'Dispatcher' => 2, 'Worker' => 3 })),
                    start + 1)

        expect(board.problems.map { [it.text, it.first_line] })
          .to eq([['Solid Queue Supervisor has no fresh heartbeat', 'last one 500 s ago'],
                  ['Solid Queue Scheduler has no fresh heartbeat', nil]])
        expect(row('Worker').status).to eq(:fail)
      end

      it 'calls a new failed job a problem, with its error, and keeps the newest count' do
        board.apply(:database, good(database(failed_new: 1, failed_first: 'boom')), start + 1)
        board.apply(:database, good(database(failed_new: 3, failed_first: 'boom')), start + 61)

        expect(board.problems.map { [it.text, it.first_line] }).to eq([['3 new', 'boom']])
        expect(row('Failed jobs').text).to eq('3 new')
      end

      it 'shows older failed jobs, and does not blame this deploy for them' do
        board.apply(:dynos, good([]), start)
        board.apply(:database, good(database(failed_old: 2)), start + 1)

        expect(row('Failed jobs')).to have_attributes(status: :ok, text: '0 (2 older)')
      end

      it 'calls no ledger check, a mismatch, a failed check and an old check problems' do
        board.apply(:database, good(database(ledger: nil)), start + 1)
        board.apply(:database, good(database(ledger: { at: start - 60, checked: 4, mismatches: 2, error: '' })),
                    start + 2)
        board.apply(:database,
                    good(database(ledger: { at: start - 60, checked: 0, mismatches: 0, error: 'it broke' })), start + 3)
        board.apply(:database,
                    good(database(ledger: { at: start - (27 * 3600), checked: 4, mismatches: 0, error: '' })),
                    start + 4)

        expect(board.problems.map(&:key)).to eq(%w[none mismatch error old])
        expect(board.problems.map(&:text).join).to include('2 mismatches', 'it failed', 'too long ago',
                                                           'No ledger check')
      end

      it 'names the date of a ledger check from another day' do
        board.apply(:database,
                    good(database(ledger: { at: start - (25 * 3600), checked: 4, mismatches: 0, error: '' })),
                    start + 4)

        expect(row('Ledger').text).to match(/\Alast check Oct 2\d .*: 4 settlements, 0 mismatches/)
      end
    end

    describe 'the jobs' do
      let(:due_at) { Time.utc(2026, 10, 30, 12, 12, 0) }

      it 'waits while a job is due later in the watch' do
        board.apply(:database, good(database), start + 60)

        expect(row('Jobs')).to have_attributes(status: :wait)
        expect(row('Jobs').text).to start_with('none finished yet (next: hourly')
      end
    end

    describe 'a job due during the watch' do
      let(:due_at) { Time.utc(2026, 10, 30, 12, 12, 0) }
      let(:start) { due_at - 1 }

      # A first read near the start, so the board has seen the whole time.
      before do
        board.apply(:database, good(database), start + 1)
        board.apply(:database, good(database), due_at + 150)
      end

      it 'does not call a job late inside its grace time' do
        board.apply(:database, good(database), due_at + 299)

        expect(board.problems).to eq([])
      end

      it 'calls a job that did not run a problem, once its grace time is over' do
        board.apply(:database, good(database), due_at + 301)

        expect(board.problems.map(&:key)).to eq(["hourly #{due_at.to_i}"])
        expect(row('Jobs', due_at + 301).status).to eq(:fail)
      end

      it 'calls a job that started and did not finish a problem' do
        board.apply(:database, good(database(jobs: [{ key: 'hourly', at: due_at, finished: false }])), due_at + 301)

        expect(row('Jobs', due_at + 301).text).to include('hourly was due at')
      end

      it 'passes a job that finished, and names it' do
        board.apply(:database, good(database(jobs: [{ key: 'hourly', at: due_at, finished: true }])), due_at + 301)

        expect(row('Jobs', due_at + 301)).to have_attributes(status: :ok)
        expect(row('Jobs', due_at + 301).text).to start_with('1 finished (last: hourly')
      end
    end

    describe 'the jobs row with nothing to judge' do
      it 'says so when nothing is due before the end, and when nothing is due at all' do
        quiet = described_class.new(started_at: start, ends_at: start + 60, known:, schedule:, first_release:,
                                    bugsnag_skipped: nil)
        quiet.apply(:database, good(database), start + 10)
        expect(quiet.rows(start + 10).find { it.name == 'Jobs' }.text)
          .to include('no scheduled job due before', '(next: hourly')

        none = described_class.new(started_at: start, ends_at: start + 60, known:,
                                   schedule: DeployWatch::Schedule.new({}),
                                   first_release:, bugsnag_skipped: nil)
        none.apply(:database, good(database), start + 10)
        expect(none.rows(start + 10).find { it.name == 'Jobs' }.text).to include('no job in the next two days')
      end

      it 'could not check when the schedule holds a form it does not read' do
        odd = described_class.new(started_at: start, ends_at: ends, known:,
                                  schedule: DeployWatch::Schedule.new({ 'odd' => '0 3 * * 1 UTC' }),
                                  first_release:, bugsnag_skipped: nil)

        expect(odd.rows(start).find { it.name == 'Jobs' }).to have_attributes(status: :unknown)
      end
    end

    it 'calls a release that did not succeed a problem' do
      board.apply(:release, good(first_release.merge(status: 'failed')), start + 1)

      expect(board.problems.map(&:text)).to eq(['Release v619 has status failed'])
    end

    it 'skips Bugsnag with the reason, and does not pass it' do
      skipped = described_class.new(started_at: start, ends_at: ends, known:, schedule:, first_release:,
                                    bugsnag_skipped: 'no token')

      expect(skipped.rows(start).last).to have_attributes(status: :not_checked, text: 'not checked: no token')
    end

    it 'shows a Bugsnag error with no message' do
      board.apply(:bugsnag, good([{ name: 'TypeError', message: nil, context: 'GET /x' }]), start + 1)

      expect(board.problems.first.first_line).to eq('GET /x')
    end
  end

  describe DeployWatch::Report do
    def rollback(list, backups = nil) = report.rollback_lines(list, backups).join("\n")

    it 'goes back past a config change, to the release before the deploy' do
      list = [
        { 'version' => 620, 'status' => 'succeeded', 'description' => 'Set X config vars',
          'created_at' => '2026-10-30T12:00:00Z' }, *releases
      ]

      expect(rollback(list)).to include('-f release=v618 ')
    end

    it 'goes back past a failed release' do
      list = [releases.first, { 'version' => 618, 'status' => 'failed', 'description' => 'Deploy bbbb',
                                'created_at' => '2026-10-29T00:00:00Z' },
              { 'version' => 617, 'status' => 'succeeded', 'description' => 'Deploy cccc',
                'created_at' => '2026-10-28T00:00:00Z' }]

      expect(rollback(list)).to include('-f release=v617 ')
    end

    it 'treats the newest release as the deploy when none says so' do
      list = [{ 'version' => 2, 'status' => 'succeeded', 'description' => 'Set X',
                'created_at' => '2026-10-30T12:00:00Z' },
              { 'version' => 1, 'status' => 'succeeded', 'description' => 'Set Y',
                'created_at' => '2026-10-20T12:00:00Z' }]

      expect(rollback(list)).to include('-f release=v1 ')
    end

    it 'says where to look when there is no earlier release' do
      expect(rollback(releases.first(1))).to include('-f release="<the release before this deploy, in: ' \
                                                     'heroku releases -a comeals-monorepo>"')
    end

    it 'names the newest finished backup from before the deploy' do
      text = <<~TEXT
        a300   2026-10-30 11:58:00 +0000   Completed 2026-10-30 11:59:00 +0000   3MB   SILVER
        b299   2026-10-30 11:54:00 +0000   Running
        b298   2026-10-30 11:50:00 +0000   Completed 2026-10-30 11:50:02 +0000   3MB   SILVER
        a297   2026-10-29 01:09:44 +0000   Completed 2026-10-29 01:12:17 +0000   3MB   SILVER
      TEXT

      expect(rollback(releases, text)).to include('-f backup=b298 ')
    end

    it 'says where to look when no backup is from before the deploy' do
      expect(rollback(releases,
                      "a300   2026-10-30 11:58:00 +0000   Completed x\n"))
        .to include('heroku pg:backups -a comeals-monorepo>"')
    end

    it 'prints a plain progress line' do
      expect(report.plain_progress(start + 90)).to end_with('1:30 of 30:00')
    end
  end

  describe DeployWatch::Shell do
    it 'gives the last line of the error output, and fails when the command fails' do
      result = described_class.run('sh', '-c', 'echo first >&2; echo; echo last >&2; exit 3', timeout: 5)

      expect(result.to_a).to eq([false, "\n", 'last'])
    end

    it 'gives a failed result for a command that does not exist' do
      expect(described_class.run('no-such-command-here', timeout: 5).ok).to be(false)
    end

    it 'stops a command that runs past its limit, and everything under it' do
      result = described_class.run('sh', '-c', 'sleep 30 & wait', timeout: 0.3)

      expect(result.error).to eq('no answer after 0.3 s')
      expect(described_class::RUNNING).to be_empty
    end

    it 'sends input the command never reads, with no error' do
      expect(described_class.run('true', input: 'x' * 100_000, timeout: 5).ok).to be(true)
    end

    it 'does nothing when asked to stop a process that is gone' do
      expect(described_class.stop_group(99_999_999)).to be_nil
    end
  end

  describe DeployWatch::Reads do
    let(:reads) { described_class.new(app: 'comeals-monorepo', url: 'https://comeals.com', since: start, token: 'x') }

    it 'reads the tables it names, as they are in this schema, and writes nothing' do
      job = SolidQueue::Job.create!(queue_name: 'default', class_name: 'X', finished_at: start + 5)
      SolidQueue::RecurringExecution.create!(job:, task_key: 'hourly', run_at: start + 720)
      SolidQueue::Process.create!(kind: 'Worker', name: 'w', pid: 1, last_heartbeat_at: Time.current)
      failed_job = SolidQueue::Job.create!(queue_name: 'default', class_name: 'Y')
      SolidQueue::FailedExecution.create!(job: failed_job, created_at: start + 5,
                                          error: { message: "two\nlines" }.to_json)
      LedgerCheckRun.create!(started_at: start, finished_at: start + 1, reconciliations_checked: 4, mismatch_count: 1,
                             details: [], error: nil)

      lines = ActiveRecord::Base.connection.select_values(described_class.database_select(start))

      expect(lines).to include('failed_new=1', 'failed_old=0', 'end=ok', "job=hourly|#{(start + 720).to_i}|true",
                               "ledger=#{(start + 1).to_i}|4|1|", a_string_matching(/\Aheartbeat=Worker\|\d+\z/),
                               a_string_matching(/\Afailed_first=.*two/))
    end

    it 'never raises: an error of any kind is a failed read' do
      allow(reads).to receive(:release).and_raise(TypeError)

      expect(reads.read(:release)).to have_attributes(ok: false,
                                                      error: 'release: an answer this script cannot read (TypeError)')
    end
  end

  describe 'DeployWatch.env_file_value' do
    it 'gives nil with no file, and reads the last line that sets the name, without quotes' do
      Dir.mktmpdir do |dir|
        file = File.join(dir, '.env')
        expect(DeployWatch.env_file_value('A', file)).to be_nil

        File.write(file, %(A=1\nAB=9\nexport A='two=2'\n))
        expect(DeployWatch.env_file_value('A', file)).to eq('two=2')
        expect(DeployWatch.env_file_value('B', file)).to be_nil
      end
    end
  end
end
