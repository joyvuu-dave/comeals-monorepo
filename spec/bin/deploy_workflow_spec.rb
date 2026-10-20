# frozen_string_literal: true

require 'rails_helper'

# The scripts the weekly Deploy workflow (.github/workflows/deploy.yml)
# runs, one per step, with fake heroku, gh, git, curl, claude and the
# rest (spec/support/script_sandbox.rb). The workflow passes each step's
# inputs as variables; the examples pass the same ones.
RSpec.describe 'the Deploy workflow scripts', bash_coverage: BashCoverage.new('spec/bin/deploy_workflow_spec.rb') do
  include_context 'with a script sandbox'

  let(:sandbox) { new_sandbox(real: %w[python3]) }
  let(:candidate) { 'c' * 40 }
  let(:live) { 'l' * 40 }
  let(:prod) { '-a comeals-monorepo' }
  let(:apps) { { 'PROD_APP' => 'comeals-monorepo', 'STAGING_APP' => 'comeals-staging' } }

  # The files the scripts source or run besides themselves.
  before { %w[bin/lib/json.sh bin/rollback-check bin/smoke].each { sandbox.link(it) } }

  def heroku_calls = sandbox.call_lines('heroku')

  describe 'bin/lib/deploy/hold-check' do
    def hold(value) = sandbox.run_script('bin/lib/deploy/hold-check', env: { 'DEPLOY_HOLD' => value })

    it 'passes when there is no hold' do
      result = hold('')

      expect(result.exitstatus).to eq(0)
      expect(result.out).to eq('')
    end

    it 'fails the run with the reason when there is a hold' do
      result = hold('rolled back 2026-10-19: The bills page is blank')

      expect(result.exitstatus).to eq(1)
      expect(result.out).to eq("DEPLOY_HOLD is set: rolled back 2026-10-19: The bills page is blank\n" \
                               "Fix main (usually git revert), then clear the variable.\n")
    end

    # The reason is text a person typed into the Rollback workflow.
    it 'prints a reason with quotes and shell characters as it is' do
      reason = %(rolled back: "it broke" `date` $(date) $HOME)

      result = hold(reason)

      expect(result.exitstatus).to eq(1)
      expect(result.out.lines.first).to eq("DEPLOY_HOLD is set: #{reason}\n")
      expect(sandbox.calls).to be_empty
    end
  end

  describe 'bin/lib/deploy/compare' do
    before { sandbox.rule('git', 'rev-parse HEAD', out: "#{candidate}\n") }

    def compare = sandbox.run_script('bin/lib/deploy/compare', env: apps)

    it 'goes on when production runs another commit' do
      sandbox.rule('heroku', "config:get HEROKU_SLUG_COMMIT #{prod}", out: "#{live}\n")

      result = compare

      expect(result.exitstatus).to eq(0)
      expect(result.outputs).to eq('candidate' => candidate, 'live' => live, 'proceed' => 'true')
      expect(result.out).to include("Candidate #{candidate}; production runs #{live}.")
    end

    it 'stops the deploy when production already runs the candidate' do
      sandbox.rule('heroku', "config:get HEROKU_SLUG_COMMIT #{prod}", out: "#{candidate}\n")

      result = compare

      expect(result.exitstatus).to eq(0)
      expect(result.outputs['proceed']).to eq('false')
      expect(result.out).to include('nothing to deploy')
    end
  end

  describe 'bin/lib/deploy/green-gate' do
    def gate(runs)
      sandbox.rule('gh', "api repos/{owner}/{repo}/commits/#{candidate}/check-runs --paginate --jq *",
                   out: runs.map { "#{it}\n" }.join)
      sandbox.run_script('bin/lib/deploy/green-gate', env: { 'CANDIDATE' => candidate })
    end

    it 'passes when every check succeeded, was neutral or was skipped' do
      result = gate(%w[ruby-test|completed|success node-lint|completed|neutral mutant|completed|skipped])

      expect(result.exitstatus).to eq(0)
      expect(result.out).to eq("All CI checks green.\n")
      expect(sandbox.calls_to('gh').map(&:args).first.last).to include('select(.name != "daily-deploy")')
    end

    it 'refuses when no check ran' do
      result = gate([])

      expect(result.exitstatus).to eq(1)
      expect(result.out).to include("No CI runs found for #{candidate}")
    end

    it 'refuses and names every check that is still running or did not pass' do
      result = gate(%w[ruby-test|in_progress|pending node-lint|completed|failure e2e|completed|cancelled
                       ruby-lint|completed|success])

      expect(result.exitstatus).to eq(1)
      expect(result.out).to eq("still running: ruby-test\nfailure: node-lint\ncancelled: e2e\n" \
                               "CI is not green for #{candidate}.\n")
    end
  end

  describe 'bin/lib/deploy/write-release-note' do
    let(:commits) { "- Fix the bills page\n  It was blank.\n" }

    before do
      sandbox.rule('git', "log --reverse --format=- %s%n%w(0,2,2)%b #{live}..#{candidate}", out: commits)
      sandbox.rule('heroku', "apps:info #{prod} --json", out: '{"app":{"stack":{"name":"heroku-24"}}}')
      sandbox.rule('heroku', 'apps:info -a comeals-staging --json', out: '{"app":{"build_stack":{"name":"heroku-24"}}}')
      sandbox.rule('npm', 'install -g @anthropic-ai/claude-code')
      sandbox.rule('claude', '-p', out: "## What changed\n- The bills page shows again.\n", capture_stdin: true)
      sandbox.rule('date', '-u +%Y%m%d-%H%M', out: "20261019-1200\n")
    end

    def write_note
      sandbox.run_script('bin/lib/deploy/write-release-note',
                         env: apps.merge('LIVE' => live, 'CANDIDATE' => candidate, 'ANTHROPIC_API_KEY' => 'test-key'))
    end

    def note = File.read(File.join(sandbox.root, 'note.md'))
    def prompt = sandbox.stdin_of('claude').first

    it 'asks Claude for the note with the commits on stdin, and names the tag' do
      result = write_note

      expect(result.exitstatus).to eq(0)
      expect(result.out).to eq("Note written by Claude.\n")
      expect(result.outputs).to eq('tag' => 'deploy-20261019-1200')
      expect(note).to eq("## What changed\n- The bills page shows again.\n")
      expect(prompt).to start_with("Below are the commit messages going into today's deploy of Comeals,\n")
      expect(prompt).to end_with("under What changed.\n\n#{commits}")
      expect(prompt).not_to include('base image')
    end

    it 'takes away a code fence around the whole note' do
      sandbox.rule('claude', '-p', out: "```markdown\n## What changed\n- A fix.\n```\n")

      write_note

      expect(note).to eq("## What changed\n- A fix.\n")
    end

    it 'takes away only the first line when the fence is not closed' do
      sandbox.rule('claude', '-p', out: "```markdown\n## What changed\n- A fix.\n")

      write_note

      expect(note).to eq("## What changed\n- A fix.\n")
    end

    it 'falls back to the commit list when Claude fails' do
      sandbox.rule('claude', '-p', err: 'API error', exit: 1)

      result = write_note

      expect(result.exitstatus).to eq(0)
      expect(result.err).to eq("Claude call failed — falling back to the commit list.\nAPI error")
      expect(note).to eq("Automatically generated commit list (note generator was unavailable):\n\n#{commits}")
      expect(result.outputs).to eq('tag' => 'deploy-20261019-1200')
    end

    it 'falls back to the commit list when Claude writes nothing' do
      sandbox.rule('claude', '-p')

      write_note

      expect(note).to start_with('Automatically generated commit list')
    end

    context 'when the next release moves to a new stack' do
      before do
        sandbox.rule('heroku', 'apps:info -a comeals-staging --json',
                     out: '{"app":{"build_stack":{"name":"heroku-26"}}}')
      end

      let(:fact) do
        'This deploy also moves the app from the heroku-24 base image to heroku-26 (the operating system image ' \
          'Heroku runs the app on).'
      end

      it 'tells Claude' do
        result = write_note

        expect(result.out).to include('Stack change detected: heroku-24 -> heroku-26')
        expect(prompt).to include("One more known fact that is not in the commits: #{fact}\n" \
                                  "Report it under What changed, in one sentence.\n")
      end

      it 'puts it above the commit list when Claude fails' do
        sandbox.rule('claude', '-p', exit: 1)

        write_note

        expect(note).to eq("Automatically generated commit list (note generator was unavailable):\n\n" \
                           "#{fact}\n\n#{commits}")
      end
    end

    it 'leaves the stack out when a probe fails' do
      sandbox.rule('heroku', 'apps:info -a comeals-staging --json', exit: 1)

      result = write_note

      expect(result.exitstatus).to eq(0)
      expect(prompt).not_to include('base image')
    end

    it 'cuts a note longer than GitHub allows and says so' do
      sandbox.rule('claude', '-p', out: "#{'x' * 99}\n" * 1300)

      write_note

      expect(note.bytesize).to be < 125_000
      expect(note).to start_with('x' * 99)
      expect(note).to end_with("\n\n(The note was longer than GitHub allows in a release body, so it\n" \
                               "ends here. The full commit list: git log #{live}..#{candidate})\n")
      expect(note.index("\n\n(The note")).to eq(120_000)
    end
  end

  describe 'bin/lib/deploy/solid-queue-config' do
    def configure(pool:)
      sandbox.rule('heroku', "config:get RAILS_DB_POOL #{prod}", out: "#{pool}\n")
      sandbox.rule('heroku', "config:set RAILS_DB_POOL=4 #{prod}")
      sandbox.run_script('bin/lib/deploy/solid-queue-config', env: apps)
    end

    def sets = heroku_calls.grep(/config:set/)

    # The jobs run on the worker dyno, so SOLID_QUEUE_IN_PUMA is not read
    # or set any more.
    it 'writes nothing when the pool is already 4 or more' do
      result = configure(pool: '5')

      expect(result.exitstatus).to eq(0)
      expect(result.out).to eq("RAILS_DB_POOL=5 is set.\n")
      expect(heroku_calls).to eq(["heroku config:get RAILS_DB_POOL #{prod}"])
    end

    ['', '3', 'four'].each do |pool|
      it "sets only the pool when RAILS_DB_POOL is '#{pool}'" do
        result = configure(pool:)

        expect(result.exitstatus).to eq(0)
        expect(result.out).to include("Setting RAILS_DB_POOL=4 (was '#{pool}').")
        expect(sets).to eq(["heroku config:set RAILS_DB_POOL=4 #{prod}"])
      end
    end
  end

  describe 'bin/lib/deploy/promote' do
    before do
      sandbox.rule('heroku', "config:get HEROKU_SLUG_COMMIT #{prod}", out: "#{live}\n")
      sandbox.rule('heroku', 'pipelines:promote -a comeals-staging')
      sandbox.rule('date', '-u +%Y-%m-%dT%H:%M:%S', out: "2026-10-19T12:30:00\n")
    end

    def promote = sandbox.run_script('bin/lib/deploy/promote', env: apps.merge('CANDIDATE' => candidate))

    it 'promotes the slug staging runs and notes when, and what ran before' do
      sandbox.rule('heroku', 'config:get HEROKU_SLUG_COMMIT -a comeals-staging', out: "#{candidate}\n")

      result = promote

      expect(result.exitstatus).to eq(0)
      expect(result.outputs).to eq('started' => '2026-10-19T12:30:00', 'previous' => live)
      expect(heroku_calls.last).to eq('heroku pipelines:promote -a comeals-staging')
    end

    it 'refuses when staging runs another commit' do
      sandbox.rule('heroku', 'config:get HEROKU_SLUG_COMMIT -a comeals-staging', out: "#{live}\n")

      result = promote

      expect(result.exitstatus).to eq(1)
      expect(result.out).to include("Staging runs #{live}, not the candidate — refusing to promote.")
      expect(heroku_calls.grep(/promote/)).to be_empty
      expect(result.outputs).to be_empty
    end
  end

  describe 'bin/lib/deploy/watch-production' do
    let(:version_url) { 'https://comeals.com/api/v1/version' }
    let(:diff) { "diff --name-only --diff-filter=A #{live} #{candidate} -- db/migrate" }

    before do
      sandbox.rule('curl', "-sf #{version_url}", out: %({"version":"614","commit":"#{candidate}"}))
      sandbox.rule('node', 'tests/smoke/smoke.js')
      sandbox.rule('heroku', "ps:scale worker=1 #{prod}")
      sandbox.rule('heroku', "ps:scale worker=0 #{prod}")
      sandbox.rule('git', "show #{live}:Procfile", out: "web: puma\nworker: bin/jobs\n")
      sandbox.rule('heroku', "run --exit-code bin/rake deploy:verify_solid_queue #{prod}")
      sandbox.rule('heroku', "logs -n 1500 #{prod}", out: "2026-10-19T12:35:00.1+00:00 app[web.1]: Started GET /\n")
      sandbox.rule('heroku', "rollback #{prod}")
      sandbox.rule('heroku', "releases #{prod} -n 3", out: "v614 Deploy failed\n")
      sandbox.rule('git', diff)
      sandbox.rule('sleep')
    end

    def watch
      sandbox.run_script('bin/lib/deploy/watch-production',
                         env: apps.merge('CANDIDATE' => candidate, 'PREVIOUS' => live,
                                         'STARTED' => '2026-10-19T12:30:00',
                                         'PROD_URL' => 'https://comeals.com'))
    end

    def rollbacks = heroku_calls.grep(/heroku rollback/)

    it 'waits for the candidate, smokes it, checks Solid Queue, watches the logs, and keeps it' do
      sandbox.rule('curl', "-sf #{version_url}", out: %({"version":"613","commit":"#{live}"}), once: true)

      result = watch

      expect(result.exitstatus).to eq(0), result.out + result.err
      expect(result.out).to include("Production serves the candidate.\n")
      expect(result.out).to end_with("No worrying lines in the production logs.\n")
      expect(sandbox.calls_to('sleep').map(&:args)).to eq([['5'], ['180']])
      expect(sandbox.calls_to('node')).not_to be_empty
      expect(rollbacks).to be_empty
    end

    # A promote starts no dyno of a process type that is new or at 0. The
    # first promote whose release has a worker process type makes one at
    # 0, so the step starts it before it asks whether Solid Queue came up.
    it 'starts the worker dyno once production serves the candidate, before the Solid Queue check' do
      result = watch

      expect(result.exitstatus).to eq(0)
      scale = heroku_calls.index("heroku ps:scale worker=1 #{prod}")
      expect(scale).not_to be_nil
      expect(scale).to be < heroku_calls.index("heroku run --exit-code bin/rake deploy:verify_solid_queue #{prod}")
    end

    it 'rolls back when the worker dyno cannot be started' do
      sandbox.rule('heroku', "ps:scale worker=1 #{prod}", exit: 1)

      result = watch

      expect(result.exitstatus).to eq(1)
      expect(result.out).to include('Could not start the worker dyno on production. Rolling back.')
      expect(rollbacks).to eq(["heroku rollback #{prod}"])
    end

    # The worker dyno can take longer to boot than the smoke test takes.
    it 'asks again after 30 seconds when Solid Queue is not up yet' do
      sandbox.rule('heroku', "run --exit-code bin/rake deploy:verify_solid_queue #{prod}", exit: 1, once: true)

      result = watch

      expect(result.exitstatus).to eq(0)
      expect(result.out).to include('Solid Queue is not up yet. Asking again in 30 seconds.')
      expect(sandbox.calls_to('sleep').map(&:args)).to eq([['30'], ['180']])
      expect(rollbacks).to be_empty
    end

    # The release before the worker dyno runs no Solid Queue. The new
    # code's jobs must not go on running beside the old code, and after
    # the rollback Heroku would refuse to scale a process type the release
    # does not have, so the worker goes to 0 first.
    it 'stops the worker dyno before rolling back to a release without one, and says so' do
      sandbox.rule('node', 'tests/smoke/smoke.js', exit: 1)
      sandbox.rule('git', "show #{live}:Procfile", out: "web: puma\nrelease: bin/rake db:migrate\n")

      result = watch

      expect(result.exitstatus).to eq(1)
      expect(result.out).to include("The release before has no worker dyno, so the worker goes to 0 and stays there.\n")
      expect(heroku_calls.last(2)).to eq(["heroku ps:scale worker=0 #{prod}", "heroku rollback #{prod}"])
    end

    it 'treats a release whose Procfile cannot be read as one without a worker dyno' do
      sandbox.rule('node', 'tests/smoke/smoke.js', exit: 1)
      sandbox.rule('git', "show #{live}:Procfile", exit: 128, err: 'fatal: bad object')

      result = watch

      expect(result.exitstatus).to eq(1)
      expect(heroku_calls.last(2)).to eq(["heroku ps:scale worker=0 #{prod}", "heroku rollback #{prod}"])
    end

    it 'rolls back anyway, and says what to run, when the worker cannot be stopped' do
      sandbox.rule('node', 'tests/smoke/smoke.js', exit: 1)
      sandbox.rule('git', "show #{live}:Procfile", out: "web: puma\n")
      sandbox.rule('heroku', "ps:scale worker=0 #{prod}", exit: 1)

      result = watch

      expect(result.exitstatus).to eq(1)
      expect(result.out).to include("Could not stop the worker dyno. Run: heroku ps:scale worker=0 #{prod}")
      expect(rollbacks).to eq(["heroku rollback #{prod}"])
    end

    it 'leaves the worker to Heroku when the release before has one' do
      sandbox.rule('node', 'tests/smoke/smoke.js', exit: 1)

      watch

      expect(heroku_calls.grep(/worker=0/)).to be_empty
      expect(rollbacks).to eq(["heroku rollback #{prod}"])
    end

    context 'when production never serves the candidate' do
      before { sandbox.rule('curl', "-sf #{version_url}", exit: 7) }

      it 'rolls back when the new slug is current' do
        sandbox.rule('heroku', "config:get HEROKU_SLUG_COMMIT #{prod}", out: "#{candidate}\n")

        result = watch

        expect(result.exitstatus).to eq(1)
        expect(result.out).to include("Production never started serving #{candidate} (still ).")
        expect(result.out).to include('v614 Deploy failed')
        expect(result.out).to include('The slug is current but not serving — rolling back.')
        expect(rollbacks).to eq(["heroku rollback #{prod}"])
        expect(sandbox.calls_to('sleep').map(&:args)).to eq([['5']] * 60)
      end

      it 'does not roll back when production still runs the old release' do
        sandbox.rule('heroku', "config:get HEROKU_SLUG_COMMIT #{prod}", out: "#{live}\n")
        sandbox.rule('heroku', "releases #{prod} -n 3", exit: 1)

        result = watch

        expect(result.exitstatus).to eq(1)
        expect(result.out).to include('Production still runs the old release — nothing to roll back.')
        expect(rollbacks).to be_empty
      end
    end

    it 'rolls back when the smoke test fails' do
      sandbox.rule('node', 'tests/smoke/smoke.js', exit: 1)

      result = watch

      expect(result.exitstatus).to eq(1)
      expect(result.out).to include('Smoke failed on production. Rolling back.')
      expect(rollbacks).to eq(["heroku rollback #{prod}"])
    end

    it 'does not roll back only the code when the release added a migration' do
      sandbox.rule('node', 'tests/smoke/smoke.js', exit: 1)
      sandbox.rule('git', diff, out: "db/migrate/20261015000000_add_thing.rb\n")

      result = watch

      expect(result.exitstatus).to eq(1)
      expect(result.out).to include('Not rolling back only the code. Follow docs/runbooks/undo-a-deploy.md.')
      expect(rollbacks).to be_empty
    end

    it 'rolls back when Solid Queue did not come up after two tries' do
      sandbox.rule('heroku', "run --exit-code bin/rake deploy:verify_solid_queue #{prod}", exit: 1)

      result = watch

      expect(result.exitstatus).to eq(1)
      expect(result.out).to include('Solid Queue is not running on production. Rolling back.')
      expect(heroku_calls.grep(/verify_solid_queue/).size).to eq(2)
      expect(rollbacks).to eq(["heroku rollback #{prod}"])
    end

    it 'rolls back on a worrying log line after the promote, and only on those' do
      sandbox.rule('heroku', "logs -n 1500 #{prod}", out: <<~LOGS)
        2026-10-19T12:29:59.9+00:00 app[web.1]: FATAL from before the deploy
        2026-10-19T12:30:00.1+00:00 app[web.1]: ok
        2026-10-19T12:31:00.1+00:00 heroku[router]: at=info status=500 path=/api/v1/meals
      LOGS

      result = watch

      expect(result.exitstatus).to eq(1)
      expect(result.out).to include(
        "Worrying production log lines after the deploy:\n" \
        "2026-10-19T12:31:00.1+00:00 heroku[router]: at=info status=500 path=/api/v1/meals\nRolling back."
      )
      expect(result.out).not_to include('from before the deploy')
      expect(rollbacks).to eq(["heroku rollback #{prod}"])
    end

    # With no logs to read the soak cannot know whether the release logged
    # an error, so the run fails and a person looks. It does not roll back:
    # the release passed the smoke test and the Solid Queue check.
    it 'fails, without rolling back, when the logs cannot be read' do
      sandbox.rule('heroku', "logs -n 1500 #{prod}", err: 'Internal server error', exit: 1)

      result = watch

      expect(result.exitstatus).to eq(1)
      expect(result.out).to include('Could not read the production logs')
      expect(result.out).not_to include('No worrying lines')
      expect(rollbacks).to be_empty
    end

    it 'keeps a release whose only worrying lines are from before the promote' do
      sandbox.rule('heroku', "logs -n 1500 #{prod}", out: "2026-10-19T12:29:59.9+00:00 app[web.1]: FATAL old\n")

      expect(watch.exitstatus).to eq(0)
      expect(rollbacks).to be_empty
    end
  end

  describe 'bin/lib/deploy/ping-healthchecks' do
    def ping(url, status)
      sandbox.rule('curl')
      sandbox.run_script('bin/lib/deploy/ping-healthchecks', env: { 'HC_URL' => url, 'JOB_STATUS' => status })
    end

    it 'pings nothing when there is no URL' do
      expect(ping('', 'success').exitstatus).to eq(0)
      expect(sandbox.calls).to be_empty
    end

    it 'pings the URL when the job succeeded' do
      expect(ping('https://hc.example.com/abc', 'success').exitstatus).to eq(0)
      expect(sandbox.call_lines).to eq(['curl -fsS -m 10 --retry 3 https://hc.example.com/abc'])
    end

    it 'pings /fail when the job failed or was cancelled' do
      ping('https://hc.example.com/abc', 'failure')
      ping('https://hc.example.com/abc', 'cancelled')

      expect(sandbox.call_lines).to eq(['curl -fsS -m 10 --retry 3 https://hc.example.com/abc/fail'] * 2)
    end

    it 'does not fail the run when the ping fails' do
      sandbox.rule('curl', '*', exit: 28)

      result = sandbox.run_script('bin/lib/deploy/ping-healthchecks',
                                  env: { 'HC_URL' => 'https://hc.example.com/abc', 'JOB_STATUS' => 'success' })

      expect(result.exitstatus).to eq(0)
    end
  end
end
