# frozen_string_literal: true

require 'rails_helper'

# bin/staging-rehearsal, run with fake heroku, git, curl, node and the
# rest (spec/support/script_sandbox.rb). Each failure test also says
# which state the script leaves staging in.
RSpec.describe 'bin/staging-rehearsal', bash_coverage: BashCoverage.new('spec/bin/staging_rehearsal_spec.rb') do
  include_context 'with a script sandbox'

  let(:sandbox) { new_sandbox(real: %w[python3]) }
  let(:sha) { 'a' * 40 }
  let(:staging) { '-a comeals-staging' }
  let(:url) { 'https://staging.example.com' }
  let(:config_keys) { %w[COMEALS_STAGING DATABASE_URL PUSHER_KEY] }

  # The files the rehearsal runs or sources besides itself, and every
  # call answered the way a good rehearsal sees it.
  before do
    %w[bin/lib/output.sh bin/lib/json.sh bin/lib/staging_forbidden_vars.sh bin/smoke].each { sandbox.link(it) }
    sandbox.note_env('SMOKE_URL', 'SMOKE_EMAIL', 'SMOKE_PASSWORD', 'SMOKE_MEAL_ID')
    sandbox.rule('heroku', "config #{staging} --json", out: config_json(config_keys))
    sandbox.rule('heroku', "config:get COMEALS_STAGING #{staging}", out: "1\n")
    sandbox.rule('heroku', "ps #{staging} --json", out: '[{"type":"web","state":"down"}]')
    sandbox.rule('heroku', 'pg:backups:capture -a comeals-monorepo',
                 out: "Backing up DATABASE to b101... done\n")
    sandbox.rule('heroku', 'pg:backups:url -a comeals-monorepo', out: "https://backups.example.com/b101\n")
    sandbox.rule('heroku', "ps:scale * #{staging}")
    sandbox.rule('heroku', "pg:backups:restore https://backups.example.com/b101 DATABASE_URL #{staging} " \
                           '--confirm comeals-staging')
    sandbox.rule('heroku', "releases #{staging} --json", out: '[{"status":"succeeded"},{"status":"failed"}]')
    sandbox.rule('heroku', "run --exit-code #{staging} -- bin/rails db:migrate", out: "== migrated ==\n")
    sandbox.rule('heroku', "run --exit-code #{staging} -- bin/rake *")
    sandbox.rule('heroku', "run --exit-code #{staging} --env * -- bin/rails runner bin/lib/staging_smoke_seed.rb",
                 out: "Smoke resident ready\nSMOKE_MEAL_ID=42\n")
    sandbox.rule('heroku', "apps:info #{staging} --json", out: %({"app":{"web_url":"#{url}/"}}))
    sandbox.rule('heroku', "config:get HEROKU_SLUG_COMMIT #{staging}", out: "#{sha}\n")
    sandbox.rule('heroku', "logs -n 1500 #{staging}", out: "2026-10-19T12:06:00.000000+00:00 app[web.1]: fine\n")
    sandbox.rule('git', 'rev-parse HEAD', out: "#{sha}\n")
    sandbox.rule('git', 'rev-parse --short HEAD', out: "aaaaaaa\n")
    sandbox.rule('git', 'push --force https://git.heroku.com/comeals-staging.git HEAD:refs/heads/main')
    sandbox.rule('curl', "-sf #{url}/api/v1/version", out: '{"version":"1"}')
    sandbox.rule('node', 'tests/smoke/*')
    sandbox.rule('openssl', 'rand -hex 16', out: "made-up-password\n")
    sandbox.rule('sleep')
    # The first date is when the rehearsal started, the second when
    # staging first answered.
    sandbox.rule('date', '-u +%Y-%m-%dT%H:%M:%S', out: "2026-10-19T12:05:00\n")
    sandbox.rule('date', '-u +%Y-%m-%dT%H:%M:%S', out: "2026-10-19T12:00:00\n", once: true)
  end

  def config_json(keys) = "{#{keys.map { %("#{it}": "1") }.join(', ')}}"

  def rehearse(env = {})
    sandbox.run_script('bin/staging-rehearsal', env:)
  end

  def heroku_calls = sandbox.call_lines('heroku')

  # The calls that change staging or production. A neuter check that
  # refuses must refuse before any of them.
  def writes
    sandbox.call_lines.grep(/pg:backups:capture|pg:backups:restore|ps:scale|git push|heroku run/)
  end

  # What staging's web formation was last scaled to, or nil if the
  # script never scaled it.
  def last_web_scale
    heroku_calls.grep(/ps:scale web=/).last&.[](/web=(\d)/, 1)
  end

  # The same for the worker, which runs Solid Queue.
  def last_worker_scale
    heroku_calls.grep(/ps:scale.* worker=|ps:scale worker=/).last&.[](/worker=(\d)/, 1)
  end

  it 'rehearses the commit and parks staging when every step passes' do
    result = rehearse

    expect(result.exitstatus).to eq(0), result.out + result.err
    expect(result.out).to include("Rehearsal passed: #{sha} is ready to promote.")
    expect(sandbox.unexpected_calls).to be_empty
    expect(sandbox.call_lines).to eq(
      [
        'date -u +%Y-%m-%dT%H:%M:%S',
        "heroku config #{staging} --json",
        "heroku config:get COMEALS_STAGING #{staging}",
        "heroku ps #{staging} --json",
        'heroku pg:backups:capture -a comeals-monorepo',
        'heroku pg:backups:url -a comeals-monorepo',
        "heroku ps:scale web=0 #{staging}",
        "heroku ps:scale worker=0 #{staging}",
        "heroku pg:backups:restore https://backups.example.com/b101 DATABASE_URL #{staging} --confirm comeals-staging",
        'git rev-parse HEAD',
        'git rev-parse --short HEAD',
        'git push --force https://git.heroku.com/comeals-staging.git HEAD:refs/heads/main',
        "heroku releases #{staging} --json",
        'mktemp',
        "heroku run --exit-code #{staging} -- bin/rails db:migrate",
        "heroku run --exit-code #{staging} -- bin/rake billing:recalculate",
        "heroku run --exit-code #{staging} -- bin/rake ledger:verify",
        'openssl rand -hex 16',
        'mktemp',
        "heroku run --exit-code #{staging} --env SMOKE_EMAIL=smoke@staging.invalid;" \
        'SMOKE_PASSWORD=made-up-password -- bin/rails runner bin/lib/staging_smoke_seed.rb',
        "heroku ps:scale web=1 worker=1 #{staging}",
        "heroku apps:info #{staging} --json",
        "curl -sf #{url}/api/v1/version",
        'date -u +%Y-%m-%dT%H:%M:%S',
        "heroku config:get HEROKU_SLUG_COMMIT #{staging}",
        "heroku run --exit-code #{staging} -- bin/rake deploy:verify_solid_queue",
        "heroku run --exit-code #{staging} -- bin/rake deploy:verify_recurring_job",
        "heroku logs -n 1500 #{staging}",
        'node tests/smoke/smoke.js',
        'node tests/smoke/aggressive.js',
        "heroku ps:scale web=0 worker=0 #{staging}"
      ]
    )
  end

  # Staging is neutered (the neuter check below), so its jobs can run:
  # mail is collected in memory, Pusher is a no-op, and there is no
  # healthchecks key. Running the worker there is how the rehearsal
  # proves the jobs dyno of this commit starts.
  it 'runs the worker beside web and checks that every Solid Queue process came up' do
    result = rehearse

    expect(result.exitstatus).to eq(0)
    expect(result.out).to include('Solid Queue runs on staging (supervisor, dispatcher, worker, scheduler)')
  end

  # The worker line in the Procfile sets the jobs dyno's pool, so staging
  # needs no RAILS_DB_POOL config var either, the same as production.
  it 'reads and sets no RAILS_DB_POOL on staging' do
    result = rehearse

    expect(result.exitstatus).to eq(0)
    expect(heroku_calls.grep(/RAILS_DB_POOL|config:set/)).to be_empty
  end

  it 'asks again after 30 seconds when Solid Queue is not up yet' do
    sandbox.rule('heroku', "run --exit-code #{staging} -- bin/rake deploy:verify_solid_queue", exit: 1, once: true)

    result = rehearse

    expect(result.exitstatus).to eq(0)
    expect(result.out).to include('Solid Queue is not up yet — asking again in 30s')
    expect(sandbox.calls_to('sleep').map(&:args)).to eq([['30']])
  end

  # Staging state: web and the worker at 1, the new code on the copy of
  # production. The Deploy workflow's "Park staging" step stops both.
  it 'stops when Solid Queue does not come up on staging' do
    sandbox.rule('heroku', "run --exit-code #{staging} -- bin/rake deploy:verify_solid_queue", exit: 1)

    result = rehearse

    expect(result.exitstatus).to eq(1)
    expect(result.out).to include('Solid Queue did not come up on staging. Read: heroku logs -a comeals-staging ' \
                                  '--dyno worker')
    expect(heroku_calls.grep(/verify_solid_queue/).size).to eq(2)
    expect(sandbox.calls_to('node')).to be_empty
    expect(last_worker_scale).to eq('1')
  end

  # On 2026-10-20 every heartbeat was fresh on staging while the scheduler
  # failed at every tick. This check queues a recurring task the way the
  # scheduler does and waits for the worker to run it.
  it 'stops when the worker does not run a queued recurring task' do
    sandbox.rule('heroku', "run --exit-code #{staging} -- bin/rake deploy:verify_recurring_job", exit: 1)

    result = rehearse

    expect(result.exitstatus).to eq(1)
    expect(result.out).to include('A recurring task queued on staging did not run. ' \
                                  'Read the error above and: heroku logs -a comeals-staging --dyno worker')
    expect(heroku_calls.grep(/verify_recurring_job/).size).to eq(1)
    expect(sandbox.calls_to('node')).to be_empty
    expect(last_worker_scale).to eq('1')
  end

  it 'passes the smoke resident and the smoke meal to both smoke tests' do
    rehearse

    smoke, aggressive = sandbox.calls_to('node')
    login = { 'SMOKE_EMAIL' => 'smoke@staging.invalid', 'SMOKE_PASSWORD' => 'made-up-password' }
    expect(smoke.env).to eq(login.merge('SMOKE_URL' => url))
    expect(aggressive.env).to eq(login.merge('SMOKE_URL' => url, 'SMOKE_MEAL_ID' => '42'))
  end

  it 'leaves web and the worker running when STAGING_KEEP_UP is 1' do
    result = rehearse('STAGING_KEEP_UP' => '1')

    expect(result.exitstatus).to eq(0)
    expect(result.out).not_to include('Park')
    expect(last_web_scale).to eq('1')
    expect(last_worker_scale).to eq('1')
  end

  describe 'the neuter check' do
    # Staging is left exactly as it was: nothing captured, restored,
    # pushed, scaled or run.
    shared_examples 'a refusal before any write' do |message|
      it "refuses: #{message}" do
        result = rehearse

        expect(result.exitstatus).not_to eq(0)
        expect(result.out).to include(message) if message
        expect(writes).to be_empty
      end
    end

    context 'when COMEALS_STAGING is not set' do
      let(:config_keys) { %w[DATABASE_URL] }

      before { sandbox.rule('heroku', "config:get COMEALS_STAGING #{staging}", out: "\n") }

      it_behaves_like 'a refusal before any write', 'COMEALS_STAGING is not set'
    end

    # The app reads COMEALS_STAGING with present?, so a blank value turns
    # the mail and Pusher guards off (config/environments/production.rb,
    # config/initializers/pusher.rb).
    context 'when COMEALS_STAGING is set but blank' do
      before { sandbox.rule('heroku', "config:get COMEALS_STAGING #{staging}", out: "  \n") }

      it_behaves_like 'a refusal before any write', 'COMEALS_STAGING is not set or is blank'
    end

    %w[GMAIL_USERNAME GMAIL_APP_PASSWORD HEALTHCHECKS_PING_KEY BUGSNAG_API_KEY VITE_BUGSNAG_API_KEY
       SKYLIGHT_AUTHENTICATION].each do |var|
      context "when #{var} is set" do
        let(:config_keys) { ['COMEALS_STAGING', var] }

        it_behaves_like 'a refusal before any write', "#{var} is set on comeals-staging"
      end
    end

    it 'does not take a name that only contains a forbidden one' do
      sandbox.rule('heroku', "config #{staging} --json", out: config_json(%w[COMEALS_STAGING OLD_GMAIL_USERNAME_NOTE]))

      expect(rehearse.exitstatus).to eq(0)
    end

    context 'when a clock dyno runs' do
      before { sandbox.rule('heroku', "ps #{staging} --json", out: '[{"type":"web"},{"type":"clock"}]') }

      it_behaves_like 'a refusal before any write', 'A clock dyno is running'
    end

    context 'when the config cannot be read' do
      before { sandbox.rule('heroku', "config #{staging} --json", err: 'Invalid credentials', exit: 1) }

      it_behaves_like 'a refusal before any write', nil
    end

    context 'when the dynos cannot be listed' do
      before { sandbox.rule('heroku', "ps #{staging} --json", err: 'Invalid credentials', exit: 1) }

      it_behaves_like 'a refusal before any write', nil
    end
  end

  # Staging state: untouched. Nothing on staging changed yet.
  it 'stops before staging changes when the production backup fails' do
    sandbox.rule('heroku', 'pg:backups:capture -a comeals-monorepo', err: 'backup failed', exit: 1)

    result = rehearse

    expect(result.exitstatus).not_to eq(0)
    expect(heroku_calls.grep(/ps:scale|restore/)).to be_empty
  end

  # Staging state: web at 0, the database whatever the failed restore
  # left. A new rehearsal restores it again.
  # A dyno takes up to 30 seconds to stop after ps:scale returns. A
  # worker still running when production's backup replaces the database
  # finds no solid_queue tables there, and its shutdown fails.
  it 'waits until no web or worker dyno runs before it restores' do
    sandbox.rule('heroku', "ps #{staging} --json", out: '[{"type":"worker","state":"up"}]', once: true)
    sandbox.rule('heroku', "ps #{staging} --json", out: '[]', once: true)

    expect(rehearse.exitstatus).to eq(0)

    lines = heroku_calls
    ps_calls = lines.each_index.select { |i| lines[i] == "heroku ps #{staging} --json" }
    restore = lines.index { it.start_with?('heroku pg:backups:restore') }
    expect(ps_calls.length).to be >= 3
    expect(restore).to be > ps_calls[2]
    expect(lines.index("heroku ps:scale worker=0 #{staging}")).to be < ps_calls[1]
  end

  it 'stops without restoring when a dyno still runs 3 minutes after the scale to 0' do
    sandbox.rule('heroku', "ps #{staging} --json", out: '[{"type":"worker","state":"up"}]')
    sandbox.rule('heroku', "ps #{staging} --json", out: '[]', once: true)

    result = rehearse

    expect(result.exitstatus).not_to eq(0)
    expect(result.output).to include('still runs 3 minutes after')
    expect(heroku_calls.grep(/pg:backups:restore/)).to be_empty
    expect(sandbox.calls_to('git').map(&:args)).to be_empty
  end

  it 'stops with web and the worker at 0 when the restore fails' do
    sandbox.rule('heroku', 'pg:backups:restore *', err: 'restore failed', exit: 1)

    result = rehearse

    expect(result.exitstatus).not_to eq(0)
    expect(last_web_scale).to eq('0')
    expect(last_worker_scale).to eq('0')
    expect(sandbox.calls_to('git').map(&:args)).to be_empty
  end

  # A staging release from before the worker dyno has no worker process
  # type, and Heroku refuses to scale one.
  it 'goes on when the worker cannot be scaled to 0 before the first deploy with one' do
    sandbox.rule('heroku', "ps:scale worker=0 #{staging}", err: "Couldn't find that process type (worker).", exit: 1)

    expect(rehearse.exitstatus).to eq(0)
    expect(heroku_calls).to include("heroku ps:scale web=1 worker=1 #{staging}")
  end

  it 'goes on when web cannot be scaled to 0 before the first deploy' do
    sandbox.rule('heroku', "ps:scale web=0 #{staging}", err: "Couldn't find that process type (web).", exit: 1,
                                                        once: true)

    expect(rehearse.exitstatus).to eq(0)
    expect(heroku_calls).to include("heroku run --exit-code #{staging} -- bin/rails db:migrate")
  end

  # Staging state: web at 0, the restored copy of production, the old
  # code.
  it 'stops with web at 0 when the push fails' do
    sandbox.rule('git', 'push *', err: 'rejected', exit: 1)

    result = rehearse

    expect(result.exitstatus).not_to eq(0)
    expect(last_web_scale).to eq('0')
    expect(heroku_calls.grep(/releases|heroku run/)).to be_empty
  end

  # Staging state: web at 0, the restored copy, and a failed release (the
  # old code still runs).
  it 'shows the release output and stops when the release phase failed' do
    sandbox.rule('heroku', "releases #{staging} --json", out: '[{"status":"failed"}]')
    sandbox.rule('heroku', "releases:output #{staging}", out: "#{"line\n" * 40}migration error\n")

    result = rehearse

    expect(result.exitstatus).to eq(1)
    expect(result.out).to include('The release phase failed (status: failed)')
    expect(result.out).to include('migration error')
    expect(result.out.lines.count("line\n")).to eq(29)
    expect(last_web_scale).to eq('0')
    expect(heroku_calls.grep(/heroku run/)).to be_empty
  end

  # Staging state for every step from here to the seed: web at 0, the new
  # code on the restored copy.
  it 'stops when the migrations fail on the copy of production' do
    sandbox.rule('heroku', "run --exit-code #{staging} -- bin/rails db:migrate", out: "boom\n", exit: 1)

    result = rehearse

    expect(result.exitstatus).to eq(1)
    expect(result.out).to include('Migrations failed on a copy')
    expect(heroku_calls.grep(%r{bin/rake})).to be_empty
    expect(last_web_scale).to eq('0')
  end

  it 'stops when the migrations print a deprecation warning' do
    sandbox.rule('heroku', "run --exit-code #{staging} -- bin/rails db:migrate",
                 out: "== migrated ==\nDEPRECATION WARNING: old thing\n")

    result = rehearse

    expect(result.exitstatus).to eq(1)
    expect(result.out).to include('Migrations printed deprecation warnings:')
    expect(result.out.lines.last).to eq("DEPRECATION WARNING: old thing\n")
    expect(heroku_calls.grep(%r{bin/rake})).to be_empty
  end

  %w[billing:recalculate ledger:verify].each do |task|
    it "stops when #{task} fails on the copy of production" do
      sandbox.rule('heroku', "run --exit-code #{staging} -- bin/rake #{task}", exit: 1)

      result = rehearse

      expect(result.exitstatus).to eq(1)
      expect(result.out).to include("#{task} failed on a copy of today's production data")
      expect(heroku_calls.grep(/staging_smoke_seed/)).to be_empty
      expect(last_web_scale).to eq('0')
    end
  end

  it 'stops when the smoke seed fails' do
    sandbox.rule('heroku', "run --exit-code #{staging} --env * -- bin/rails runner *", out: "Refusing\n", exit: 1)

    result = rehearse

    expect(result.exitstatus).to eq(1)
    expect(result.out).to include('Smoke seed failed')
    expect(last_web_scale).to eq('0')
  end

  it 'stops and says so when the smoke seed prints no meal id' do
    sandbox.rule('heroku', "run --exit-code #{staging} --env * -- bin/rails runner *", out: "Smoke resident ready\n")

    result = rehearse

    expect(result.exitstatus).to eq(1)
    expect(result.out).to include('Smoke seed printed no SMOKE_MEAL_ID')
    expect(last_web_scale).to eq('0')
  end

  # Staging state from here on, for every failure: web at 1 (not parked),
  # running the new code on the copy of production. In the Deploy
  # workflow its "Park staging" step scales it to 0 after a failure; run
  # by hand, staging stays up until a person parks it.
  it 'stops after 30 tries when staging never answers, and shows the logs' do
    sandbox.rule('curl', "-sf #{url}/api/v1/version", exit: 22)
    sandbox.rule('heroku', "logs -n 100 #{staging}", out: "log line\n" * 40)

    result = rehearse

    expect(result.exitstatus).to eq(1)
    expect(result.out).to include('Staging did not answer /api/v1/version within 60s')
    expect(result.out.lines.count("log line\n")).to eq(30)
    expect(sandbox.calls_to('curl').map(&:args).size).to eq(30)
    expect(sandbox.calls_to('sleep').map(&:args)).to eq([['2']] * 30)
    expect(last_web_scale).to eq('1')
  end

  it 'waits until staging answers' do
    sandbox.rule('curl', "-sf #{url}/api/v1/version", exit: 7, once: true)

    result = rehearse

    expect(result.exitstatus).to eq(0)
    expect(sandbox.calls_to('curl').map(&:args).size).to eq(2)
    expect(sandbox.calls_to('sleep').map(&:args)).to eq([['2']])
  end

  it 'stops when staging runs another commit' do
    sandbox.rule('heroku', "config:get HEROKU_SLUG_COMMIT #{staging}", out: "#{'b' * 40}\n")

    result = rehearse

    expect(result.exitstatus).to eq(1)
    expect(result.out).to include("Staging runs #{'b' * 40}, expected #{sha}")
    expect(last_web_scale).to eq('1')
  end

  describe 'the log check' do
    def with_logs(*lines)
      sandbox.rule('heroku', "logs -n 1500 #{staging}", out: lines.map { "#{it}\n" }.join)
      rehearse
    end

    it 'stops on a worrying line from this rehearsal' do
      result = with_logs('2026-10-19T12:01:00.1+00:00 app[web.1]: ok',
                         '2026-10-19T12:06:00.1+00:00 heroku[router]: at=error code=H10 status=503',
                         '2026-10-19T12:06:01.1+00:00 app[web.1]: DEPRECATION WARNING: soon')

      expect(result.exitstatus).to eq(1)
      expect(result.out).to include('Worrying lines in the staging logs:')
      expect(result.out).to include('code=H10 status=503')
      expect(result.out).to include('DEPRECATION WARNING: soon')
      expect(result.out).not_to include('app[web.1]: ok')
      expect(last_web_scale).to eq('1')
    end

    it 'shows at most 20 worrying lines' do
      lines = Array.new(25) { format('2026-10-19T12:06:%<second>02d.1+00:00 app[web.1]: FATAL %<second>d', second: it) }

      result = with_logs(*lines)

      expect(result.out.scan(/FATAL \d+/).size).to eq(20)
    end

    it 'leaves out lines from before the rehearsal, the boot H14s, migration SQL and pg_restore lines' do
      result = with_logs(
        '2026-10-19T11:59:59.9+00:00 app[web.1]: FATAL from an earlier run',
        '2026-10-19T12:02:00.1+00:00 heroku[router]: at=error code=H14 status=503 desc="No web processes running"',
        '2026-10-19T12:03:00.1+00:00 app[release.7]: -- execute("RAISE EXCEPTION ...")',
        '2026-10-19T12:04:00.1+00:00 app[api]: pg_restore: error: could not execute query',
        '2026-10-19T12:06:00.1+00:00 app[web.1]: Started GET /'
      )

      expect(result.exitstatus).to eq(0), result.out
      expect(result.out).to include('No worrying lines in the staging logs')
    end

    it 'counts an H14 after staging first answered' do
      result = with_logs('2026-10-19T12:05:30.1+00:00 heroku[router]: at=error code=H14 status=503')

      expect(result.exitstatus).to eq(1)
      expect(result.out).to include('code=H14')
    end

    # With no logs to read the check cannot know whether the release or the
    # boot logged an error, so it must not pass.
    it 'fails when the logs cannot be read' do
      sandbox.rule('heroku', "logs -n 1500 #{staging}", err: 'Internal server error', exit: 1)

      result = rehearse

      expect(result.exitstatus).to eq(1)
      expect(result.out).to include('Could not read the staging logs')
      expect(result.out).not_to include('No worrying lines')
      expect(sandbox.calls_to('node').map(&:args)).to be_empty
    end

    it 'counts a release line that is not migration SQL' do
      result = with_logs('2026-10-19T12:03:00.1+00:00 app[release.7]: PG::Error ERROR Exception in migration')

      expect(result.exitstatus).to eq(1)
    end
  end

  it 'stops when the read-only smoke fails' do
    sandbox.rule('node', 'tests/smoke/smoke.js', out: "login page failed\n", exit: 1)

    result = rehearse

    expect(result.exitstatus).to eq(1)
    expect(result.out).to include('login page failed')
    expect(sandbox.call_lines('node')).to eq(['node tests/smoke/smoke.js'])
    expect(last_web_scale).to eq('1')
  end

  it 'stops when the aggressive smoke fails' do
    sandbox.rule('node', 'tests/smoke/aggressive.js', exit: 1)

    result = rehearse

    expect(result.exitstatus).to eq(1)
    expect(result.out).not_to include('Aggressive smoke passed')
    expect(last_web_scale).to eq('1')
  end
end
