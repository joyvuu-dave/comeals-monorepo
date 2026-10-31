# frozen_string_literal: true

require 'rails_helper'
require_relative 'watch_deploy_fakes/watch_harness'

# bin/watch-deploy, run for real against fake heroku and curl commands, with a
# clock that runs 60 times faster than real time, so a one-minute watch takes
# one real second. The rules for single lines and single reads are in
# spec/bin/watch_deploy_units_spec.rb; this file runs whole watches.
RSpec.describe 'bin/watch-deploy' do
  include_context 'with a script sandbox'

  let(:watch) { WatchHarness.new(sandbox) }
  # Every Heroku command the watch may send. Each one only reads.
  let(:read_only_heroku) do
    [/\Aheroku releases --json -a /, /\Aheroku config:get HEROKU_SLUG_COMMIT -a /, /\Aheroku maintenance -a /,
     /\Aheroku ps --json -a /, /\Aheroku pg:psql -c SET TRANSACTION READ ONLY; SELECT .* -a /,
     /\Aheroku pg:backups -a /,
     /\Aheroku logs --tail -n 1500 -a /, /\Aheroku logs -n 1500 -a /]
  end

  def line_for(seconds, source, text) = WatchHarness.log_line(seconds, source, text)

  def expect_only_reads
    expect(watch.heroku_calls).not_to be_empty
    expect(watch.heroku_calls).to all(satisfy { |call| read_only_heroku.any? { call.match?(it) } })
  end

  it 'starts from its own shebang and says how to use it' do
    out, status = run_ruby_script(Rails.root.join('bin/watch-deploy').to_s, '--help')

    expect(status).to be_success
    expect(out).to include('Usage: [DEPLOY_APP=comeals-staging] bin/watch-deploy [--minutes N]', '--minutes')
  end

  describe 'a watch where all is well' do
    let!(:result) { watch.run('--minutes', '1') }

    it 'says ALL CLEAR, lists each check, and exits 0' do
      expect(result.status.exitstatus).to eq(0)
      expect(result.output).to include(
        'Comeals deploy watch · comeals-monorepo · v619 (c28c3052)',
        'Started 7:00 am CDT · ends 7:01 am CDT',
        'ALL CLEAR',
        'Watched v619 for 1 minute. 10 checks, 0 problems. Not checked: Bugsnag.',
        'Release        v619 running c28c3052, maintenance off',
        'Web            up · 212 MB of 512 MB · no restarts',
        'Worker         up · 241 MB · Solid Queue heartbeat 18 s ago',
        'Site           /  and  /api/v1/version → 200 (checked 3 times)',
        'Requests       2 · no 5xx · no H or R codes',
        'App errors     none',
        'Jobs           no scheduled job due before 7:01 am (next: clear_finished_jobs 7:12 am)',
        'Failed jobs    0',
        'Ledger         last check 6:57 am: 4 settlements, 0 mismatches',
        'Warnings       none new',
        'skipped  Bugsnag        not checked: BUGSNAG_AUTH_TOKEN is not in .env'
      )
    end

    it 'prints plain lines with no colors and no bar, because its output is not a terminal' do
      expect(result.output).not_to match(/\e\[|█|░|✅/)
    end

    it 'saves the report, which says the same' do
      expect(watch.report).to include('ALL CLEAR', 'Ledger         last check 6:57 am',
                                      "Report saved in #{WatchHarness::REPORT}")
      expect(result.output).to include("Report saved in #{WatchHarness::REPORT}")
    end

    it 'sends Heroku only commands that read, and never asks for the config vars' do
      expect_only_reads
      expect(watch.heroku_calls.join("\n")).not_to match(/releases:info|ledger:verify|heroku config -|heroku run/)
    end

    it 'checks the site at both paths' do
      expect(watch.curl_calls.map { it.split.last }.uniq).to contain_exactly('https://comeals.com/',
                                                                             'https://comeals.com/api/v1/version')
    end
  end

  describe 'which app it watches' do
    it 'watches staging when DEPLOY_APP says so, where Bugsnag does not apply' do
      watch.write_env("BUGSNAG_AUTH_TOKEN=abcdefghij\n")

      result = watch.run('--minutes', '1', env: { 'DEPLOY_APP' => 'comeals-staging' })

      expect(result.status.exitstatus).to eq(0)
      expect(result.output).to include('comeals-staging · v619', 'not checked: staging has no Bugsnag key')
      expect(watch.heroku_calls).to all(end_with('-a comeals-staging'))
      expect(watch.curl_calls.map { it.split.last }).to include('https://comeals-staging-ad51b8a1eb64.herokuapp.com/api/v1/version')
      expect(watch.curl_calls.join).not_to include('bugsnag')
    end

    ['', 'comeals-prod', 'COMEALS-MONOREPO'].each do |name|
      it "refuses DEPLOY_APP=#{name.inspect} before it reads anything" do
        result = watch.run(env: { 'DEPLOY_APP' => name })

        expect(result.status.exitstatus).to eq(1)
        expect(result.output).to include(%(DEPLOY_APP is "#{name}".),
                                         'It must be comeals-monorepo or comeals-staging. Nothing was read.')
        expect(watch.heroku_calls + watch.curl_calls).to eq([])
      end
    end
  end

  describe '--minutes' do
    [%w[--minutes 0], %w[--minutes -3], %w[--minutes abc], %w[--nope]].each do |args|
      it "refuses #{args.join(' ')}" do
        result = watch.run(*args)

        expect(result.status.exitstatus).to eq(1)
        expect(result.output).to include('Usage:')
        expect(watch.heroku_calls + watch.curl_calls).to eq([])
      end
    end
  end

  describe 'when Heroku cannot be read at the start' do
    it 'says so, starts no watch and exits 1' do
      watch.answers(:releases, err: "Error: not logged in\n", exit: 1)

      result = watch.run('--minutes', '1')

      expect(result.status.exitstatus).to eq(1)
      expect(result.output).to include('Could not read comeals-monorepo from Heroku, so the watch did not start. ' \
                                       'heroku releases: Error: not logged in')
      expect(result.output).not_to include('ALL CLEAR')
    end

    it 'says so when the heroku command is not installed' do
      watch
      FileUtils.rm(File.join(sandbox.fakebin, 'heroku'))

      result = watch.run('--minutes', '1')

      expect(result.status.exitstatus).to eq(1)
      expect(result.output).to include('Could not read comeals-monorepo from Heroku')
    end

    it 'says so when Heroku names no commit, the same as a failed read' do
      watch.answers(:commit, out: "\n")

      result = watch.run('--minutes', '1')

      expect(result.status.exitstatus).to eq(1)
      expect(result.output).to include('heroku config:get: no commit in the answer')
    end

    it 'says so when maintenance answers neither on nor off' do
      watch.answers(:maintenance, out: "maybe\n")

      result = watch.run('--minutes', '1')

      expect(result.status.exitstatus).to eq(1)
      expect(result.output).to include('the answer was not on or off: maybe')
    end
  end

  describe 'when a check fails' do
    let(:bad_line) { WatchHarness.router(20, path: '/api/v1/meals', status: 500) }

    it 'says NEEDS A LOOK with the first log line and the rollback command filled in, and exits 1' do
      watch.answers(:tail, out: WatchHarness::LINES + bad_line + WatchHarness.router(21, status: 500), hang: true)

      result = watch.run('--minutes', '1')

      expect(result.status.exitstatus).to eq(1)
      expect(result.output).to include(
        'NEEDS A LOOK',
        'Watched v619 for 1 minute. 10 checks, 1 problem. Not checked: Bugsnag.',
        'Requests: 500 from the router',
        '(2 times), first at 7:00:20 am CDT',
        bad_line.strip,
        'gh workflow run rollback.yml --ref main -f app=comeals-monorepo -f release=v618 ' \
        '-f reason="Problems after the deploy of c28c3052, seen by bin/watch-deploy"',
        'gh workflow run rollback.yml --ref main -f app=comeals-monorepo -f release=v618 -f backup=b245 -f reason='
      )
      expect(result.output).not_to include('ALL CLEAR')
      expect(watch.report).to include('NEEDS A LOOK', bad_line.strip, '-f backup=b245')
    end

    it 'gives a command that says where to find the backup when the backups cannot be read' do
      watch.answers(:tail, out: WatchHarness::LINES + bad_line, hang: true)
      watch.answers(:backups, err: "boom\n", exit: 1)

      result = watch.run('--minutes', '1')

      expect(result.output).to include('-f backup="<the newest backup before the deploy, in: ' \
                                       'heroku pg:backups -a comeals-monorepo>"')
    end

    it 'does not count expected lines as problems' do
      expected = [WatchHarness.router(20, status: 503, extra: 'at=error code=H80 desc="Maintenance mode"'),
                  WatchHarness.router(21, status: 200,
                                          extra: 'sock=client at=warning code=H27 desc="Client Request Interrupted"'),
                  line_for(22, 'app[web.1]',
                           'I, [x #1]  INFO -- : [abc] No route matches [GET] "/wp-login.php" (404 Not Found)')]
      watch.answers(:tail, out: WatchHarness::LINES + expected.join, hang: true)

      result = watch.run('--minutes', '1')

      expect(result.status.exitstatus).to eq(0)
      expect(result.output).to include('ALL CLEAR', '2 known lines ignored', 'none (404 scanner lines ignored: 1)')
    end
  end

  describe 'when a tool fails' do
    it 'shows could not check, never passed, when every database read fails' do
      watch.answers(:psql, err: "connection refused\n", exit: 1)

      result = watch.run('--minutes', '1')

      expect(result.status.exitstatus).to eq(1)
      expect(result.output).to include('NEEDS A LOOK', 'Could not check: Worker.', 'Could not check: Jobs.',
                                       'Could not check: Failed jobs.',
                                       'Could not check: Ledger.',
                                       'UNKNOWN  Ledger         could not check: heroku pg:psql: connection refused')
      expect(result.output).not_to include('last check 6:57 am')
    end

    it 'shows could not check when a read never ends' do
      watch.answers(:ps, hang: true)

      result = watch.run('--minutes', '1')

      expect(result.status.exitstatus).to eq(1)
      expect(result.output).to include('UNKNOWN  Web            could not check: heroku ps: no answer after 60 s')
    end

    it 'shows could not check when an answer cannot be read, without printing it' do
      watch.answers(:ps, out: 'not json SECRETWORD')

      result = watch.run('--minutes', '1')

      expect(result.status.exitstatus).to eq(1)
      expect(result.output).to include('could not check: dynos: an answer this script cannot read (JSON::ParserError)')
      expect(result.output).not_to include('SECRETWORD')
    end

    it 'shows could not check when the database answer stops part way' do
      watch.answers(:psql, out: " failed_new=0\n")

      result = watch.run('--minutes', '1')

      expect(result.output).to include('could not check: heroku pg:psql: the answer stopped part way')
    end

    it 'reads a finished job, and calls no ledger check a problem' do
      watch.answers(:psql,
                    out: watch.database(ledger: nil,
                                        jobs: ["clear_finished_jobs|#{(WatchHarness::START_TIME + 720).to_i}|true"]))

      result = watch.run('--minutes', '1')

      expect(result.status.exitstatus).to eq(1)
      expect(result.output).to include('Ledger: No ledger check has ever run',
                                       'Jobs           1 finished (last: clear_finished_jobs 7:12 am)')
    end

    it 'shows could not check when curl fails at the site' do
      watch.answers(:site, err: "curl: (6) Could not resolve host\n", exit: 6)

      result = watch.run('--minutes', '1')

      expect(result.status.exitstatus).to eq(1)
      expect(result.output).to include('could not check: curl /: curl: (6) Could not resolve host')
    end

    it 'passes a check when one read failed and the reads after it were good' do
      watch.answers(:ps, { err: "timeout\n", exit: 1 }, { out: watch.dynos.to_json })

      result = watch.run('--minutes', '1')

      expect(result.status.exitstatus).to eq(0)
      expect(result.output).to include('ALL CLEAR')
    end

    it 'calls the site a problem when it answers something other than 200' do
      watch.answers(:site, { out: '200' }, { out: '503' }, { out: '200' })

      result = watch.run('--minutes', '1')

      expect(result.status.exitstatus).to eq(1)
      expect(result.output).to include('Site: / answered 503')
    end
  end

  describe 'the log stream' do
    let(:after_restart) { WatchHarness.router(200, path: '/after-the-restart') }

    it 'restarts a stream that hangs, and sees the lines of the new one' do
      faster = WatchHarness.new(sandbox, speed: 120)
      allow(self).to receive(:watch).and_return(faster)
      faster.answers(:tail, { out: WatchHarness::OLD_LINE, hang: true },
                     { out: WatchHarness::LINES + after_restart, hang: true })
      faster.answers(:logs, out: WatchHarness::LINES + after_restart)

      result = faster.run('--minutes', '5')

      expect(watch.heroku_calls.grep(/--tail/).size).to eq(2)
      expect(result.status.exitstatus).to eq(0)
      expect(result.output).to include('Log stream restarted: 1', 'Requests       3 ·')
    end

    it 'starts a stream again when it ends, and counts each line once' do
      watch.answers(:tail, { out: WatchHarness::LINES }, { out: WatchHarness::LINES, hang: true })

      result = watch.run('--minutes', '1')

      expect(watch.heroku_calls.grep(/--tail/).size).to be >= 2
      expect(result.status.exitstatus).to eq(0)
      expect(result.output).to include('Requests       2 ·')
    end

    it 'says lines were lost when a new stream starts later than the last line seen' do
      watch.answers(:tail, out: WatchHarness::OLD_LINE, hang: true)
      watch.answers(:logs, out: WatchHarness.router(50))

      result = watch.run('--minutes', '1')

      expect(result.status.exitstatus).to eq(1)
      expect(result.output).to include('UNKNOWN  Requests', 'were lost')
    end

    it 'still sees a bad line near the end when the stream died, through the last read of the log' do
      bad = WatchHarness.router(55, status: 502)
      watch.answers(:tail, { out: WatchHarness::LINES }, { exit: 1 })
      watch.answers(:logs, out: WatchHarness::LINES + bad)

      result = watch.run('--minutes', '1')

      expect(result.status.exitstatus).to eq(1)
      expect(result.output).to include('Requests: 502 from the router', bad.strip)
    end

    it 'shows could not check when the stream died and the last read of the log fails too' do
      watch.answers(:tail, { out: WatchHarness::LINES }, { exit: 1 })
      watch.answers(:logs, err: "gateway error\n", exit: 1)

      result = watch.run('--minutes', '1')

      expect(result.status.exitstatus).to eq(1)
      expect(result.output).to include('Could not check: Requests.', 'Could not check: App errors.',
                                       'Could not check: Warnings.',
                                       'the last read of the log failed (heroku logs: gateway error)')
      expect(result.output).not_to include('ALL CLEAR')
    end

    it 'waits, and never passes, while no log line has come' do
      watch.answers(:tail, hang: true)
      watch.answers(:logs, err: "gateway error\n", exit: 1)

      result = watch.run('--minutes', '1')

      expect(result.output).to include('Requests: waiting: waiting for the first read')
      expect(result.status.exitstatus).to eq(1)
    end
  end

  describe 'when something changes during the watch' do
    let(:rolled_back) do
      [{ version: 620, status: 'succeeded', description: 'Rollback to v618', created_at: '2026-10-30T12:00:30Z' },
       *WatchHarness::RELEASES]
    end

    it 'calls a changed release a problem, and gives no rollback command' do
      watch.answers(:releases, { out: WatchHarness::RELEASES.to_json }, { out: rolled_back.to_json })
      watch.answers(:commit, { out: "#{WatchHarness::COMMIT}\n" }, { out: "aaaa1111ffff\n" })

      result = watch.run('--minutes', '1')

      expect(result.status.exitstatus).to eq(1)
      expect(result.output).to include('The release changed from v619 (c28c3052) to v620 (aaaa1111)',
                                       'Rollback to v618',
                                       'no rollback command is shown', 'bin/watch-deploy again')
      expect(result.output).not_to include('gh workflow run')
    end

    it 'calls maintenance being turned on a problem' do
      watch.answers(:maintenance, { out: "off\n" }, { out: "on\n" })

      result = watch.run('--minutes', '1')

      expect(result.status.exitstatus).to eq(1)
      expect(result.output).to include('Release: Maintenance mode was turned on, first at 7:00:')
    end

    it 'calls a dyno restart seen by heroku ps a problem' do
      watch.answers(:ps, { out: watch.dynos.to_json }, { out: watch.dynos(updated_at: '2026-10-30T12:00:30Z').to_json })

      result = watch.run('--minutes', '1')

      expect(result.status.exitstatus).to eq(1)
      expect(result.output).to include('Web: web.1 restarted', 'Worker: worker.1 restarted')
    end

    it 'calls a dyno restart seen in the log a problem, with its first line' do
      restart = line_for(20, 'heroku[web.1]', 'State changed from up to starting')
      watch.answers(:tail, out: WatchHarness::LINES + restart, hang: true)

      result = watch.run('--minutes', '1')

      expect(result.status.exitstatus).to eq(1)
      expect(result.output).to include('Web: web.1 restarted', restart.strip)
    end
  end

  describe 'when the watch is stopped by hand' do
    it 'prints the report so far and exits 1 on Ctrl-C' do
      slow = WatchHarness.new(sandbox, speed: 10)

      result = slow.run_and_signal('--minutes', '30', after: 1.5)

      expect(result.status.exitstatus).to eq(1)
      expect(result.output).to include('NEEDS A LOOK', 'The watch was stopped by hand at 7:00 am CDT',
                                       'Watched v619 for 0 of 30 minutes')
      expect(slow.report).to include('stopped by hand')
    end
  end

  describe 'when the laptop sleeps' do
    it 'says the watch had a gap, does not claim those minutes, and exits 1' do
      result = watch.run('--minutes', '30', env: { 'FAKE_CLOCK_JUMP' => '30:1700' })

      expect(result.status.exitstatus).to eq(1)
      expect(result.output).to include('NEEDS A LOOK', 'The watch had a gap from 7:00 am CDT to 7:28 am CDT',
                                       'Nothing was seen in that time', 'Watched v619 for 1 of 30 minutes')
    end

    it 'cuts a gap off at the end of the watch when the laptop wakes after it' do
      result = watch.run('--minutes', '2', env: { 'FAKE_CLOCK_JUMP' => '30:3600' })

      expect(result.status.exitstatus).to eq(1)
      expect(result.output).to include('The watch had a gap from 7:00 am CDT to 7:02 am CDT',
                                       'Watched v619 for 0 of 2 minutes')
    end
  end

  describe 'on a terminal' do
    it 'draws the bar with marks and colors, then the banner' do
      watch.answers(:tail, out: WatchHarness::LINES + WatchHarness.router(9, path: '/api/v1/version'), hang: true)

      result = watch.run_on_terminal('--minutes', '1')

      expect(result.status.exitstatus).to eq(0)
      expect(result.output).to include('█', '░', '% ', ' of 1:00 ', ' left', '✅ Release', '➖ Bugsnag',
                                       "\e[32m  ALL CLEAR\e[0m",
                                       'Last event 7:00:09  GET /api/v1/version 200 (Better Stack or this watch)')
      expect(watch.report).not_to match(/\e\[|✅/)
    end

    it 'shows a stream restart and a gap while it runs, and the banner in red' do
      watch.answers(:tail, { out: WatchHarness::LINES }, { out: WatchHarness::LINES, hang: true })

      result = watch.run_on_terminal('--minutes', '30', env: { 'FAKE_CLOCK_JUMP' => '30:1700' })

      expect(result.output).to include('Log stream restarted: ', 'The watch had a gap from',
                                       "\e[31m  NEEDS A LOOK\e[0m")
      expect(result.status.exitstatus).to eq(1)
    end
  end

  describe 'Bugsnag' do
    let(:token) { 'abcd1234tokenvalue' }

    before { watch.write_env(%(OTHER=1\nexport BUGSNAG_AUTH_TOKEN="#{token}"\n)) }

    def new_error(last_seen, stages = ['production'])
      { error_class: 'TypeError', message: 'nil is not a string', context: 'GET /x', last_seen:,
        release_stages: stages }
    end

    it 'shows no new errors, and counts the check, when Bugsnag has none since the start' do
      watch.answers(:errors,
                    out: [new_error('2026-10-30T11:00:00Z'), new_error('2026-10-30T12:00:30Z', ['staging'])].to_json)

      result = watch.run('--minutes', '1')

      expect(result.status.exitstatus).to eq(0)
      expect(result.output).to include('Bugsnag        no new Bugsnag errors', '11 checks, 0 problems.')
      expect(result.output).not_to include('Not checked')
    end

    it 'calls an error since the start a problem' do
      watch.answers(:errors, out: [new_error('2026-10-30T12:00:30Z')].to_json)

      result = watch.run('--minutes', '1')

      expect(result.status.exitstatus).to eq(1)
      expect(result.output).to include('Bugsnag: New Bugsnag error: TypeError', 'nil is not a string at GET /x')
    end

    it 'shows could not check when Bugsnag cannot be read' do
      watch.answers(:errors, err: "curl: (22) 401\n", exit: 22)

      result = watch.run('--minutes', '1')

      expect(result.status.exitstatus).to eq(1)
      expect(result.output).to include('could not check: Bugsnag: curl: (22) 401')
    end

    it 'shows could not check when no project is called comeals' do
      watch.answers(:projects, out: [{ id: 'other', slug: 'x' }].to_json)

      result = watch.run('--minutes', '1')

      expect(result.output).to include('could not check: bugsnag: an answer this script cannot read (NoMethodError)')
    end

    it 'never prints the token or puts it on a command line, and sends it on the input of curl' do
      result = watch.run('--minutes', '1')

      expect(result.output).not_to include(token)
      expect(watch.report).not_to include(token)
      expect(watch.curl_calls.join(' ')).not_to include(token)
      expect(File.read(File.join(sandbox.dir, 'curl-stdin'))).to include(%(header = "Authorization: token #{token}"))
    end

    it 'treats an empty token as no token' do
      watch.write_env("BUGSNAG_AUTH_TOKEN=\n")

      result = watch.run('--minutes', '1')

      expect(result.output).to include('not checked: BUGSNAG_AUTH_TOKEN is not in .env')
      expect(watch.curl_calls.join).not_to include('bugsnag')
    end
  end

  it 'exits 1 when the known warnings list cannot be used' do
    # The list is the real one (it is shared with bin/deploy), so this runs a
    # copy of the script's folder against a broken copy of the list.
    Dir.mktmpdir do |copy|
      FileUtils.mkdir_p(File.join(copy, 'bin/lib'))
      FileUtils.mkdir_p(File.join(copy, 'docs'))
      FileUtils.mkdir_p(File.join(copy, 'config'))
      FileUtils.cp_r(Rails.root.join('bin/lib/deploy_watch'), File.join(copy, 'bin/lib'))
      FileUtils.cp(Rails.root.join('bin/watch-deploy'), File.join(copy, 'bin'))
      FileUtils.cp(Rails.root.join('config/recurring.yml'), File.join(copy, 'config'))
      File.write(File.join(copy, 'docs/deploy-known-warnings.txt'), "nonsense: 1\n")
      watch

      result = sandbox.run(RbConfig.ruby, File.join(copy, 'bin/watch-deploy'),
                           env: { 'FAKE_CLOCK_START' => WatchHarness::START })

      expect(result.status.exitstatus).to eq(1)
      expect(result.output).to include('unknown field in: nonsense: 1')
    end
  end
end
