# frozen_string_literal: true

require 'rails_helper'

# bin/staging-rehearsal, run with fake heroku, git, curl, node and the
# rest (spec/support/script_sandbox.rb). Each failure test also says
# which state the script leaves staging in.
RSpec.describe 'bin/staging-rehearsal' do
  let(:sandbox) { ScriptSandbox.new(fakes: %w[heroku git curl node openssl date sleep]) }
  let(:sha) { 'a' * 40 }
  let(:staging) { '-a comeals-staging' }
  let(:url) { 'https://staging.example.com' }
  let(:config_keys) { %w[COMEALS_STAGING DATABASE_URL PUSHER_KEY] }

  after { sandbox.cleanup }

  # Every call answered the way a good rehearsal sees it.
  before do
    sandbox.record_env('SMOKE_URL', 'SMOKE_EMAIL', 'SMOKE_PASSWORD', 'SMOKE_MEAL_ID')
    sandbox.fake('heroku', "config #{staging} --json", out: config_json(config_keys))
    sandbox.fake('heroku', "addons #{staging}", out: "heroku-postgresql (postgresql-round-123)  essential-0\n")
    sandbox.fake('heroku', "ps #{staging} --json", out: '[{"type":"web","state":"down"}]')
    sandbox.fake('heroku', 'pg:backups:capture -a comeals-monorepo', out: "Backing up DATABASE to b101... done\n")
    sandbox.fake('heroku', 'pg:backups:url -a comeals-monorepo', out: "https://backups.example.com/b101\n")
    sandbox.fake('heroku', "ps:scale web=? #{staging}")
    sandbox.fake('heroku', "pg:backups:restore https://backups.example.com/b101 DATABASE_URL #{staging} " \
                           '--confirm comeals-staging')
    sandbox.fake('heroku', "releases #{staging} --json", out: '[{"status":"succeeded"},{"status":"failed"}]')
    sandbox.fake('heroku', "run --exit-code #{staging} -- bin/rails db:migrate", out: "== migrated ==\n")
    sandbox.fake('heroku', "run --exit-code #{staging} -- bin/rake *")
    sandbox.fake('heroku', "run --exit-code #{staging} --env * -- bin/rails runner bin/lib/staging_smoke_seed.rb",
                 out: "Smoke resident ready\nSMOKE_MEAL_ID=42\n")
    sandbox.fake('heroku', "apps:info #{staging} --json", out: %({"app":{"web_url":"#{url}/"}}))
    sandbox.fake('heroku', "config:get HEROKU_SLUG_COMMIT #{staging}", out: "#{sha}\n")
    sandbox.fake('heroku', "logs -n 1500 #{staging}", out: "2026-10-19T12:06:00.000000+00:00 app[web.1]: fine\n")
    sandbox.fake('git', 'rev-parse HEAD', out: "#{sha}\n")
    sandbox.fake('git', 'rev-parse --short HEAD', out: "aaaaaaa\n")
    sandbox.fake('git', 'push --force https://git.heroku.com/comeals-staging.git HEAD:refs/heads/main')
    sandbox.fake('curl', "-sf #{url}/api/v1/version", out: '{"version":"1"}')
    sandbox.fake('node', 'tests/smoke/*')
    sandbox.fake('openssl', 'rand -hex 16', out: "made-up-password\n")
    sandbox.fake('sleep')
    # The first date is when the rehearsal started, the second when
    # staging first answered.
    sandbox.fake('date', '-u +%Y-%m-%dT%H:%M:%S', out: "2026-10-19T12:05:00\n")
    sandbox.fake('date', '-u +%Y-%m-%dT%H:%M:%S', out: "2026-10-19T12:00:00\n", once: true)
  end

  def config_json(keys) = "{#{keys.map { %("#{it}": "1") }.join(', ')}}"

  def rehearse(env = {})
    sandbox.run('bin/staging-rehearsal', env:)
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

  it 'rehearses the commit and parks staging when every step passes' do
    result = rehearse

    expect(result.exitstatus).to eq(0), result.out + result.err
    expect(result.out).to include("Rehearsal passed: #{sha} is ready to promote.")
    expect(sandbox.unexpected_calls).to be_empty
    expect(sandbox.call_lines).to eq(
      [
        'date -u +%Y-%m-%dT%H:%M:%S',
        "heroku config #{staging} --json",
        "heroku addons #{staging}",
        "heroku ps #{staging} --json",
        'heroku pg:backups:capture -a comeals-monorepo',
        'heroku pg:backups:url -a comeals-monorepo',
        "heroku ps:scale web=0 #{staging}",
        "heroku pg:backups:restore https://backups.example.com/b101 DATABASE_URL #{staging} --confirm comeals-staging",
        'git rev-parse HEAD',
        'git rev-parse --short HEAD',
        'git push --force https://git.heroku.com/comeals-staging.git HEAD:refs/heads/main',
        "heroku releases #{staging} --json",
        "heroku run --exit-code #{staging} -- bin/rails db:migrate",
        "heroku run --exit-code #{staging} -- bin/rake billing:recalculate",
        "heroku run --exit-code #{staging} -- bin/rake ledger:verify",
        'openssl rand -hex 16',
        "heroku run --exit-code #{staging} --env SMOKE_EMAIL=smoke@staging.invalid;" \
        'SMOKE_PASSWORD=made-up-password -- bin/rails runner bin/lib/staging_smoke_seed.rb',
        "heroku ps:scale web=1 #{staging}",
        "heroku apps:info #{staging} --json",
        "curl -sf #{url}/api/v1/version",
        'date -u +%Y-%m-%dT%H:%M:%S',
        "heroku config:get HEROKU_SLUG_COMMIT #{staging}",
        "heroku logs -n 1500 #{staging}",
        'node tests/smoke/smoke.js',
        'node tests/smoke/aggressive.js',
        "heroku ps:scale web=0 #{staging}"
      ]
    )
  end

  it 'passes the smoke resident and the smoke meal to both smoke tests' do
    rehearse

    smoke, aggressive = sandbox.calls.select { it[:command] == 'node' }
    login = { 'SMOKE_EMAIL' => 'smoke@staging.invalid', 'SMOKE_PASSWORD' => 'made-up-password' }
    expect(smoke[:env]).to eq(login.merge('SMOKE_URL' => url))
    expect(aggressive[:env]).to eq(login.merge('SMOKE_URL' => url, 'SMOKE_MEAL_ID' => '42'))
  end

  it 'leaves web running when STAGING_KEEP_UP is 1' do
    result = rehearse('STAGING_KEEP_UP' => '1')

    expect(result.exitstatus).to eq(0)
    expect(result.out).not_to include('Park')
    expect(last_web_scale).to eq('1')
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

      it_behaves_like 'a refusal before any write', 'COMEALS_STAGING is not set'
    end

    # The app reads COMEALS_STAGING with present?, so a blank value turns
    # the mail and Pusher guards off (config/environments/production.rb,
    # config/initializers/pusher.rb). The check only asks whether the
    # name is there.
    context 'when COMEALS_STAGING is set but blank' do
      before { sandbox.fake('heroku', "config #{staging} --json", out: '{"COMEALS_STAGING": "", "DATABASE_URL": "x"}') }

      it_behaves_like 'a refusal before any write', 'COMEALS_STAGING'
    end

    %w[GMAIL_USERNAME GMAIL_APP_PASSWORD HEALTHCHECKS_PING_KEY BUGSNAG_API_KEY VITE_BUGSNAG_API_KEY
       SKYLIGHT_AUTHENTICATION].each do |var|
      context "when #{var} is set" do
        let(:config_keys) { ['COMEALS_STAGING', var] }

        it_behaves_like 'a refusal before any write', "#{var} is set on comeals-staging"
      end
    end

    it 'does not take a name that only contains a forbidden one' do
      sandbox.fake('heroku', "config #{staging} --json", out: config_json(%w[COMEALS_STAGING OLD_GMAIL_USERNAME_NOTE]))

      expect(rehearse.exitstatus).to eq(0)
    end

    context 'when a scheduler addon exists' do
      before { sandbox.fake('heroku', "addons #{staging}", out: "scheduler (scheduler-round-1)  standard\n") }

      it_behaves_like 'a refusal before any write', 'A scheduler addon exists'
    end

    context 'when a clock dyno runs' do
      before { sandbox.fake('heroku', "ps #{staging} --json", out: '[{"type":"web"},{"type":"clock"}]') }

      it_behaves_like 'a refusal before any write', 'A clock dyno is running'
    end

    context 'when the config cannot be read' do
      before { sandbox.fake('heroku', "config #{staging} --json", err: 'Invalid credentials', exit: 1) }

      it_behaves_like 'a refusal before any write', nil
    end

    context 'when the dynos cannot be listed' do
      before { sandbox.fake('heroku', "ps #{staging} --json", err: 'Invalid credentials', exit: 1) }

      it_behaves_like 'a refusal before any write', nil
    end

    # When the addon list cannot be read, the check cannot know whether a
    # scheduler exists, but it reports "No scheduler addon" and goes on.
    context 'when the addons cannot be listed' do
      before { sandbox.fake('heroku', "addons #{staging}", err: 'Internal server error', exit: 1) }

      it_behaves_like 'a refusal before any write', nil
    end
  end

  # Staging state: untouched. Nothing on staging changed yet.
  it 'stops before staging changes when the production backup fails' do
    sandbox.fake('heroku', 'pg:backups:capture -a comeals-monorepo', err: 'backup failed', exit: 1)

    result = rehearse

    expect(result.exitstatus).not_to eq(0)
    expect(heroku_calls.grep(/ps:scale|restore/)).to be_empty
  end

  # Staging state: web at 0, the database whatever the failed restore
  # left. A new rehearsal restores it again.
  it 'stops with web at 0 when the restore fails' do
    sandbox.fake('heroku', 'pg:backups:restore *', err: 'restore failed', exit: 1)

    result = rehearse

    expect(result.exitstatus).not_to eq(0)
    expect(last_web_scale).to eq('0')
    expect(sandbox.calls_to('git')).to be_empty
  end

  it 'goes on when web cannot be scaled to 0 before the first deploy' do
    sandbox.fake('heroku', "ps:scale web=0 #{staging}", err: "Couldn't find that process type (web).", exit: 1,
                                                        once: true)

    expect(rehearse.exitstatus).to eq(0)
    expect(heroku_calls).to include("heroku run --exit-code #{staging} -- bin/rails db:migrate")
  end

  # Staging state: web at 0, the restored copy of production, the old
  # code.
  it 'stops with web at 0 when the push fails' do
    sandbox.fake('git', 'push *', err: 'rejected', exit: 1)

    result = rehearse

    expect(result.exitstatus).not_to eq(0)
    expect(last_web_scale).to eq('0')
    expect(heroku_calls.grep(/releases|heroku run/)).to be_empty
  end

  # Staging state: web at 0, the restored copy, and a failed release (the
  # old code still runs).
  it 'shows the release output and stops when the release phase failed' do
    sandbox.fake('heroku', "releases #{staging} --json", out: '[{"status":"failed"}]')
    sandbox.fake('heroku', "releases:output #{staging}", out: "#{"line\n" * 40}migration error\n")

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
    sandbox.fake('heroku', "run --exit-code #{staging} -- bin/rails db:migrate", out: "boom\n", exit: 1)

    result = rehearse

    expect(result.exitstatus).to eq(1)
    expect(result.out).to include('Migrations failed on a copy')
    expect(heroku_calls.grep(%r{bin/rake})).to be_empty
    expect(last_web_scale).to eq('0')
  end

  it 'stops when the migrations print a deprecation warning' do
    sandbox.fake('heroku', "run --exit-code #{staging} -- bin/rails db:migrate",
                 out: "== migrated ==\nDEPRECATION WARNING: old thing\n")

    result = rehearse

    expect(result.exitstatus).to eq(1)
    expect(result.out).to include('Migrations printed deprecation warnings:')
    expect(result.out.lines.last).to eq("DEPRECATION WARNING: old thing\n")
    expect(heroku_calls.grep(%r{bin/rake})).to be_empty
  end

  %w[billing:recalculate ledger:verify].each do |task|
    it "stops when #{task} fails on the copy of production" do
      sandbox.fake('heroku', "run --exit-code #{staging} -- bin/rake #{task}", exit: 1)

      result = rehearse

      expect(result.exitstatus).to eq(1)
      expect(result.out).to include("#{task} failed on a copy of today's production data")
      expect(heroku_calls.grep(/staging_smoke_seed/)).to be_empty
      expect(last_web_scale).to eq('0')
    end
  end

  it 'stops when the smoke seed fails' do
    sandbox.fake('heroku', "run --exit-code #{staging} --env * -- bin/rails runner *", out: "Refusing\n", exit: 1)

    result = rehearse

    expect(result.exitstatus).to eq(1)
    expect(result.out).to include('Smoke seed failed')
    expect(last_web_scale).to eq('0')
  end

  # Staging state from here on, for every failure: web at 1 (not parked),
  # running the new code on the copy of production. In the Deploy
  # workflow its "Park staging" step scales it to 0 after a failure; run
  # by hand, staging stays up until a person parks it.
  it 'stops after 30 tries when staging never answers, and shows the logs' do
    sandbox.fake('curl', "-sf #{url}/api/v1/version", exit: 22)
    sandbox.fake('heroku', "logs -n 100 #{staging}", out: "log line\n" * 40)

    result = rehearse

    expect(result.exitstatus).to eq(1)
    expect(result.out).to include('Staging did not answer /api/v1/version within 60s')
    expect(result.out.lines.count("log line\n")).to eq(30)
    expect(sandbox.calls_to('curl').size).to eq(30)
    expect(sandbox.calls_to('sleep')).to eq([['2']] * 30)
    expect(last_web_scale).to eq('1')
  end

  it 'waits until staging answers' do
    sandbox.fake('curl', "-sf #{url}/api/v1/version", exit: 7, once: true)

    result = rehearse

    expect(result.exitstatus).to eq(0)
    expect(sandbox.calls_to('curl').size).to eq(2)
    expect(sandbox.calls_to('sleep')).to eq([['2']])
  end

  it 'stops when staging runs another commit' do
    sandbox.fake('heroku', "config:get HEROKU_SLUG_COMMIT #{staging}", out: "#{'b' * 40}\n")

    result = rehearse

    expect(result.exitstatus).to eq(1)
    expect(result.out).to include("Staging runs #{'b' * 40}, expected #{sha}")
    expect(last_web_scale).to eq('1')
  end

  describe 'the log check' do
    def with_logs(*lines)
      sandbox.fake('heroku', "logs -n 1500 #{staging}", out: lines.map { "#{it}\n" }.join)
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

    it 'counts a release line that is not migration SQL' do
      result = with_logs('2026-10-19T12:03:00.1+00:00 app[release.7]: PG::Error ERROR Exception in migration')

      expect(result.exitstatus).to eq(1)
    end
  end

  it 'stops when the read-only smoke fails' do
    sandbox.fake('node', 'tests/smoke/smoke.js', out: "login page failed\n", exit: 1)

    result = rehearse

    expect(result.exitstatus).to eq(1)
    expect(result.out).to include('login page failed')
    expect(sandbox.call_lines('node')).to eq(['node tests/smoke/smoke.js'])
    expect(last_web_scale).to eq('1')
  end

  it 'stops when the aggressive smoke fails' do
    sandbox.fake('node', 'tests/smoke/aggressive.js', exit: 1)

    result = rehearse

    expect(result.exitstatus).to eq(1)
    expect(result.out).not_to include('Aggressive smoke passed')
    expect(last_web_scale).to eq('1')
  end
end
