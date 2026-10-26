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
  # The four smoke sign-ins, as the production environment's secrets give
  # them to a step.
  let(:smoke_secrets) do
    { 'SMOKE_EMAIL' => 'me@example.com', 'SMOKE_PASSWORD' => 'resident-secret',
      'SMOKE_ADMIN_EMAIL' => 'admin@example.com', 'SMOKE_ADMIN_PASSWORD' => 'admin-secret' }
  end

  # The files the scripts source or run besides themselves.
  before { %w[bin/lib/json.sh bin/lib/smoke_secrets.sh bin/rollback-check bin/smoke].each { sandbox.link(it) } }

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

  # Before the run changes anything (the draft release, staging,
  # production), it smokes production as it is. A smoke login that works
  # now is what lets a refused login after the promote roll back.
  describe 'bin/lib/deploy/smoke-before' do
    before do
      sandbox.note_env('SMOKE_URL', 'SMOKE_EMAIL')
      sandbox.rule('node', 'tests/smoke/smoke.js')
    end

    def smoke_before(secrets = smoke_secrets)
      sandbox.run_script('bin/lib/deploy/smoke-before', env: apps.merge('PROD_URL' => 'https://comeals.com')
                                                                 .merge(secrets))
    end

    it 'smokes production with the sign-ins and says the login worked' do
      result = smoke_before

      expect(result.exitstatus).to eq(0)
      expect(result.out).to eq("Production passes the smoke test before the deploy, its logins included.\n")
      expect(result.outputs).to eq('login_worked' => 'true')
      expect(sandbox.calls_to('node').map(&:env))
        .to eq([{ 'SMOKE_URL' => 'https://comeals.com', 'SMOKE_EMAIL' => 'me@example.com' }])
    end

    it 'stops the run with code 2, and changes nothing, when production refuses a smoke login' do
      sandbox.rule('node', 'tests/smoke/smoke.js', exit: 2)

      result = smoke_before

      expect(result.exitstatus).to eq(2)
      expect(result.out).to eq(
        "Production refused a smoke login before the deploy. Nothing was changed. Check the SMOKE_* secrets of\n" \
        "the GitHub environment production, then run the workflow again.\n"
      )
      expect(result.outputs).to be_empty
    end

    it 'stops the run, and changes nothing, when production fails the smoke test' do
      sandbox.rule('node', 'tests/smoke/smoke.js', exit: 1)

      result = smoke_before

      expect(result.exitstatus).to eq(1)
      expect(result.out).to eq(
        "Production fails the smoke test before the deploy. Nothing was changed.\n" \
        "Find out why first: bin/smoke https://comeals.com\n"
      )
      expect(result.outputs).to be_empty
    end

    # A secret that is not set reaches the step as an empty value. The
    # smoke test would then skip that login and pass without it.
    it 'stops with code 2 before smoking, naming each missing secret but no value, when one is not set' do
      result = smoke_before(smoke_secrets.merge('SMOKE_PASSWORD' => '', 'SMOKE_ADMIN_EMAIL' => ''))

      expect(result.exitstatus).to eq(2)
      expect(result.out).to eq(
        "Missing smoke secrets: SMOKE_PASSWORD SMOKE_ADMIN_EMAIL. Set them in the GitHub environment production.\n"
      )
      expect(result.out + result.err).not_to include('resident-secret', 'admin-secret', 'me@example.com')
      expect(sandbox.calls_to('node')).to be_empty
    end
  end

  describe 'bin/lib/deploy/watch-production' do
    let(:version_url) { 'https://comeals.com/api/v1/version' }
    let(:diff) { "diff --name-only --no-renames --diff-filter=A #{live} #{candidate} -- db/migrate" }

    before do
      sandbox.rule('curl', "-sf #{version_url}", out: %({"version":"614","commit":"#{candidate}"}))
      sandbox.rule('node', 'tests/smoke/smoke.js')
      sandbox.rule('heroku', "ps:scale worker=1 #{prod}")
      sandbox.rule('heroku', "ps:scale worker=0 #{prod}")
      sandbox.rule('git', "show #{live}:Procfile", out: "web: puma\nworker: bin/jobs\n")
      sandbox.rule('heroku', "run --exit-code bin/rake deploy:verify_solid_queue #{prod}")
      sandbox.rule('heroku', "run --exit-code bin/rake deploy:verify_recurring_job #{prod}")
      sandbox.rule('heroku', "logs -n 1500 #{prod}", out: "2026-10-19T12:35:00.1+00:00 app[web.1]: Started GET /\n")
      sandbox.rule('heroku', "rollback #{prod}")
      sandbox.rule('heroku', "releases #{prod} -n 3", out: "v614 Deploy failed\n")
      sandbox.rule('git', diff)
      sandbox.rule('sleep')
    end

    def watch(secrets: smoke_secrets, login_worked_before: 'true')
      sandbox.run_script('bin/lib/deploy/watch-production',
                         env: apps.merge('CANDIDATE' => candidate, 'PREVIOUS' => live,
                                         'STARTED' => '2026-10-19T12:30:00',
                                         'PROD_URL' => 'https://comeals.com',
                                         'LOGIN_WORKED_BEFORE' => login_worked_before)
                                  .merge(secrets))
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

    # bin/smoke ends with 2 when production answered and refused a smoke
    # login. The smoke-before step proved that login worked before the
    # promote, so the release broke it.
    it 'rolls back when production refuses a smoke login that worked before the deploy' do
      sandbox.rule('node', 'tests/smoke/smoke.js', exit: 2)

      result = watch

      expect(result.exitstatus).to eq(1)
      expect(result.out).to include(
        "Production refused a smoke login that worked before the deploy, so the release broke it. Rolling back.\n"
      )
      expect(rollbacks).to eq(["heroku rollback #{prod}"])
    end

    # Without that proof the refusal may be stale secrets, and rolling back
    # would undo a good release. The other checks still run, and still
    # roll back a broken release, and the run still fails, so the release
    # note stays a draft.
    context 'when production refuses a smoke login not known to have worked before' do
      before { sandbox.rule('node', 'tests/smoke/smoke.js', exit: 2) }

      it 'does not roll back, runs the other checks, and fails at the end saying to check the secrets' do
        result = watch(login_worked_before: '')

        expect(result.exitstatus).to eq(1)
        expect(result.out).to include(
          'Production refused a smoke login. It is not known to have worked before the deploy, so this is not a ' \
          "reason to roll back. The other checks go on.\n"
        )
        expect(result.out).to end_with(
          "No worrying lines in the production logs.\n" \
          'Production passed every other check, but the smoke test could not sign in, so this run is not a pass ' \
          'and the release stays a draft. Check the SMOKE_* secrets of the GitHub environment production, then ' \
          "run: bin/smoke https://comeals.com\n"
        )
        expect(heroku_calls.grep(/deploy:verify/).map { it[/deploy:\w+/] })
          .to eq(%w[deploy:verify_solid_queue deploy:verify_recurring_job])
        expect(sandbox.calls_to('sleep').map(&:args)).to eq([['180']])
        expect(rollbacks).to be_empty
      end

      it 'still rolls back when another check fails' do
        sandbox.rule('heroku', "run --exit-code bin/rake deploy:verify_solid_queue #{prod}", exit: 1)

        result = watch(login_worked_before: '')

        expect(result.exitstatus).to eq(1)
        expect(result.out).to include('Solid Queue is not running on production. Rolling back.')
        expect(rollbacks).to eq(["heroku rollback #{prod}"])
      end
    end

    # The promote already ran, so a missing secret must not stop the watch:
    # every check still runs and can still roll back. The step then ends
    # with 2 and names what is missing.
    it 'runs every check, then ends with code 2 naming each missing secret but no value, when one is not set' do
      result = watch(secrets: smoke_secrets.merge('SMOKE_ADMIN_PASSWORD' => ''))

      expect(result.exitstatus).to eq(2)
      expect(result.out).to end_with(
        "No worrying lines in the production logs.\n" \
        "Missing smoke secrets: SMOKE_ADMIN_PASSWORD. Set them in the GitHub environment production.\n"
      )
      expect(result.out + result.err).not_to include('resident-secret', 'me@example.com')
      expect(heroku_calls.grep(/deploy:verify/).size).to eq(2)
      expect(rollbacks).to be_empty
    end

    # Any code but 0 and 2 is a broken site, or a smoke test that could
    # not run, and rolls back as before.
    it 'rolls back when the smoke test ends with any other code' do
      sandbox.rule('node', 'tests/smoke/smoke.js', exit: 127)

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

    # A process can have a heartbeat while its work fails. After the
    # heartbeats, a recurring task is queued the way the scheduler does it,
    # and the worker must run it.
    it 'checks that the worker runs a queued recurring task, after the heartbeats' do
      result = watch

      expect(result.exitstatus).to eq(0)
      checks = heroku_calls.grep(/deploy:verify/).map { it[/deploy:\w+/] }
      expect(checks).to eq(%w[deploy:verify_solid_queue deploy:verify_recurring_job])
    end

    it 'rolls back when the worker did not run a queued recurring task' do
      sandbox.rule('heroku', "run --exit-code bin/rake deploy:verify_recurring_job #{prod}", exit: 1)

      result = watch

      expect(result.exitstatus).to eq(1)
      expect(result.out).to include('A recurring task queued on production did not run. Rolling back.')
      expect(heroku_calls.grep(/verify_recurring_job/).size).to eq(1)
      expect(rollbacks).to eq(["heroku rollback #{prod}"])
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

  # Production's smoke test signs in with the owner's resident and admin
  # accounts. Only the step that smokes production gets them: the staging
  # rehearsal signs in with its own smoke resident.
  describe '.github/workflows/deploy.yml' do
    let(:steps) do
      YAML.safe_load_file(Rails.root.join('.github/workflows/deploy.yml').to_s)['jobs']['daily-deploy']['steps']
    end

    it 'gives the smoke sign-ins from the secrets to the two steps that smoke production only' do
      names = %w[SMOKE_EMAIL SMOKE_PASSWORD SMOKE_ADMIN_EMAIL SMOKE_ADMIN_PASSWORD]
      smoking = steps.select { %w[smoke_before].include?(it['id']) || it['name'] == 'Watch production' }

      expect(smoking.pluck('name')).to eq(['Smoke production before the deploy', 'Watch production'])
      smoking.each { expect(it['env'].slice(*names)).to eq(names.index_with { "${{ secrets.#{it} }}" }) }
      expect((steps - smoking).map { it['env'].to_s }.grep(/SMOKE_/)).to eq([])
      expect(YAML.safe_load_file(Rails.root.join('.github/workflows/deploy.yml').to_s)['env'].keys.grep(/SMOKE/))
        .to eq([])
    end

    # #251: the smoke tests use the Google Chrome the runner image already
    # has, not Playwright's Chromium, whose --with-deps install waits on
    # Ubuntu's package mirror. The browser is started once before the
    # staging rehearsal, so one that does not start stops the run before
    # anything changes.
    it "starts the smoke test's browser, the runner's own Chrome, before the staging rehearsal" do
      job = YAML.safe_load_file(Rails.root.join('.github/workflows/deploy.yml').to_s)['jobs']['daily-deploy']
      names = steps.pluck('name')
      check = steps.find { it['name'] == "Check that the smoke test's browser starts" }

      expect(job['env']).to eq('SMOKE_BROWSER_CHANNEL' => 'chrome')
      expect(check['run']).to eq('node tests/smoke/browser.js')
      expect(names.index(check['name'])).to be < names.index('Staging rehearsal')
      expect(steps.map { it['run'].to_s }.grep(/playwright/)).to eq([])
    end

    # Nothing may change before the smoke test of production as it is:
    # not the draft release, not staging, not production.
    it 'smokes production before any step that changes something, and tells the watch whether the login worked' do
      names = steps.pluck('name')
      before = steps.find { it['id'] == 'smoke_before' }
      watch = steps.find { it['name'] == 'Watch production' }

      expect(before['run']).to eq('bin/lib/deploy/smoke-before')
      expect(before['if']).to eq("steps.compare.outputs.proceed == 'true'")
      expect(names.index(before['name'])).to be > names.index("Check that the smoke test's browser starts")
      ['Create the draft release', 'Staging rehearsal', 'Promote to production'].each do |name|
        expect(names.index(before['name'])).to be < names.index(name)
      end
      expect(watch['env']['LOGIN_WORKED_BEFORE']).to eq('${{ steps.smoke_before.outputs.login_worked }}')
    end
  end
end
