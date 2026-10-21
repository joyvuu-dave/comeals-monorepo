# frozen_string_literal: true

require 'rails_helper'

# The scripts the Rollback workflow (.github/workflows/rollback.yml) runs,
# one per step, with fake heroku, curl, gh and git
# (spec/support/script_sandbox.rb). The workflow passes each step's
# inputs as variables; the examples pass the same ones.
RSpec.describe 'the Rollback workflow scripts', bash_coverage: BashCoverage.new('spec/bin/rollback_workflow_spec.rb') do
  include_context 'with a script sandbox'

  let(:sandbox) { new_sandbox(real: %w[python3]) }
  let(:bad) { 'b' * 40 }
  let(:good) { 'a' * 40 }
  let(:prod) { '-a comeals-monorepo' }

  # The files the scripts source or run besides themselves.
  before { %w[bin/lib/json.sh bin/rollback-check bin/smoke].each { sandbox.link(it) } }

  def heroku_calls = sandbox.call_lines('heroku')

  describe 'bin/lib/rollback/find-release' do
    let(:api) { 'https://api.heroku.com/apps/comeals-monorepo' }

    before do
      sandbox.rule('curl', "* #{api}/releases", out: '[{"version":613},{"version":612}]')
      sandbox.rule('curl', "* #{api}/releases/612", out: '{"slug":{"id":"slug-612"}}')
      sandbox.rule('curl', "* #{api}/releases/610", out: '{"slug":{"id":"slug-610"}}')
      sandbox.rule('curl', "* #{api}/slugs/slug-612",
                   out: %({"commit":"#{good}","process_types":{"web":"puma","worker":"bin/jobs"}}))
      sandbox.rule('curl', "* #{api}/slugs/slug-610", out: %({"commit":"#{'c' * 40}","process_types":{"web":"puma"}}))
      sandbox.rule('heroku', "config:get HEROKU_SLUG_COMMIT #{prod}", out: "#{bad}\n")
    end

    def find(app: 'comeals-monorepo', release: '')
      sandbox.run_script('bin/lib/rollback/find-release',
                         env: { 'APP' => app, 'RELEASE' => release, 'HEROKU_API_KEY' => 'test-key' })
    end

    it 'goes back to the release before the current one when given none' do
      result = find

      expect(result.exitstatus).to eq(0)
      expect(result.outputs).to eq('url' => 'https://comeals.com', 'target' => 'v612',
                                   'target_sha' => good, 'bad_sha' => bad, 'target_has_worker' => 'true')
      expect(result.out).to include("comeals-monorepo runs #{bad}; v612 runs #{good}.")
      expect(result.out).to include("v612 has a worker dyno, so the worker runs again after the rollback.\n")
      expect(sandbox.calls_to('curl').map(&:args)).to all(
        include('-sf', 'Accept: application/vnd.heroku+json; version=3', 'Authorization: Bearer test-key')
      )
      expect(sandbox.calls_to('curl').map(&:args).first).to include('Range: version ..; order=desc, max=2')
    end

    it 'goes back to the release it is given, with or without the v' do
      expect(find(release: 'v610').outputs['target']).to eq('v610')
      expect(find(release: '610').outputs).to include('target' => 'v610', 'target_sha' => 'c' * 40)
    end

    # The slug's process types are what Heroku runs for that release, read
    # from the Procfile it was built from. Production before the worker
    # dyno has none.
    it 'says so when the release it goes back to has no worker process type' do
      result = find(release: 'v610')

      expect(result.exitstatus).to eq(0)
      expect(result.outputs['target_has_worker']).to eq('false')
      expect(result.out).to include("v610 has no worker dyno, so the worker goes to 0 and stays there.\n")
    end

    it 'counts a slug that names no process types as one without a worker' do
      sandbox.rule('curl', "* #{api}/slugs/slug-612", out: %({"commit":"#{good}"}))

      expect(find.outputs['target_has_worker']).to eq('false')
    end

    it 'gives the staging address for the staging app' do
      staging_api = 'https://api.heroku.com/apps/comeals-staging'
      sandbox.rule('curl', "* #{staging_api}/releases", out: '[{"version":9},{"version":8}]')
      sandbox.rule('curl', "* #{staging_api}/releases/8", out: '{"slug":{"id":"s8"}}')
      sandbox.rule('curl', "* #{staging_api}/slugs/s8", out: %({"commit":"#{good}"}))
      sandbox.rule('heroku', 'config:get HEROKU_SLUG_COMMIT -a comeals-staging', out: "#{bad}\n")

      result = find(app: 'comeals-staging')

      expect(result.exitstatus).to eq(0)
      expect(result.outputs).to include('url' => 'https://comeals-staging-ad51b8a1eb64.herokuapp.com',
                                        'target' => 'v8')
    end

    # The workflow's app input is a choice of the two apps, and GitHub
    # checks a choice input. The script checks too, so another app can
    # never be rolled back and then smoked at an empty address.
    it 'refuses an app it does not know, before it reads anything' do
      result = find(app: 'some-other-app')

      expect(result.exitstatus).to eq(1)
      expect(result.out).to include('Refusing to roll back some-other-app')
      expect(result.outputs).to be_empty
      expect(sandbox.calls).to be_empty
    end

    it 'stops, changing nothing, when the release is not found' do
      sandbox.rule('curl', "* #{api}/releases/999", err: 'curl: (22) The requested URL returned error: 404', exit: 22)

      result = find(release: 'v999')

      expect(result.exitstatus).not_to eq(0)
      expect(result.outputs.keys).to eq(['url'])
      expect(heroku_calls).to be_empty
    end

    it 'stops when the release has no commit' do
      sandbox.rule('curl', "* #{api}/slugs/slug-612", out: '{"commit":null}')

      result = find

      expect(result.exitstatus).to eq(1)
      expect(result.out).to include('Could not read the commit of the running release or of v612, so nothing was ' \
                                    'changed.')
      expect(result.outputs.keys).to eq(['url'])
    end

    it 'stops when it cannot read the running commit' do
      sandbox.rule('heroku', "config:get HEROKU_SLUG_COMMIT #{prod}", out: "\n")

      result = find

      expect(result.exitstatus).to eq(1)
      expect(result.out).to include('comeals-monorepo runs an unknown commit; v612')
      expect(result.out).to include('Could not read the commit')
    end

    it 'stops when the release runs the commit that runs now' do
      sandbox.rule('heroku', "config:get HEROKU_SLUG_COMMIT #{prod}", out: "#{good}\n")

      result = find

      expect(result.exitstatus).to eq(1)
      expect(result.out).to include('v612 runs the same commit as comeals-monorepo runs now')
      expect(result.outputs.keys).to eq(['url'])
    end
  end

  describe 'bin/lib/rollback/check-migrations' do
    let(:diff) { "diff --name-only --diff-filter=A #{good} #{bad} -- db/migrate" }

    def check(backup: '', code_only: 'false')
      env = { 'TARGET_SHA' => good, 'BAD_SHA' => bad, 'BACKUP' => backup, 'CODE_ONLY_IS_SAFE' => code_only,
              'APP' => 'comeals-monorepo' }
      sandbox.run_script('bin/lib/rollback/check-migrations', env:)
    end

    it 'passes when no migration was added since the release it goes back to' do
      sandbox.rule('git', diff)

      result = check

      expect(result.exitstatus).to eq(0)
      expect(result.out).to include("No migration was added after #{good}")
      expect(sandbox.calls_to('git').map(&:args)).to eq([diff.split])
    end

    context 'when a migration was added' do
      before { sandbox.rule('git', diff, out: "db/migrate/20261001000000_add_thing.rb\n") }

      it 'refuses to roll back only the code' do
        result = check

        expect(result.exitstatus).to eq(1)
        expect(result.out).to include('  db/migrate/20261001000000_add_thing.rb')
        expect(result.out).to include('Refusing to roll back only the code.')
        expect(result.out).to include('heroku pg:backups -a comeals-monorepo')
      end

      it 'goes on when a backup is restored first' do
        result = check(backup: 'b245')

        expect(result.exitstatus).to eq(0)
        expect(result.out).to include('Backup b245 is restored first')
      end

      it 'goes on when told the old code runs beside every migration' do
        result = check(code_only: 'true')

        expect(result.exitstatus).to eq(0)
        expect(result.out).to include('rolling back only the code')
      end
    end
  end

  describe 'bin/lib/rollback/restore-backup' do
    before do
      sandbox.rule('heroku', "maintenance:on #{prod}")
      sandbox.rule('heroku', "pg:backups:capture #{prod}")
      sandbox.rule('curl', '* https://api.heroku.com/apps/comeals-monorepo/formation',
                   out: '[{"type":"web","quantity":2},{"type":"worker","quantity":1}]')
      sandbox.rule('heroku', "ps:scale web=0 worker=0 #{prod}")
      sandbox.rule('heroku', "ps:scale web=0 #{prod}")
      sandbox.rule('heroku', "ps #{prod} --json", out: '[{"type":"run"}]')
      sandbox.rule('heroku', "ps #{prod} --json", out: '[{"type":"worker"},{"type":"run"}]', once: true)
      sandbox.rule('heroku', "pg:backups:restore b245 DATABASE_URL #{prod} --confirm comeals-monorepo")
      sandbox.rule('sleep')
    end

    def restore
      sandbox.run_script('bin/lib/rollback/restore-backup',
                         env: { 'APP' => 'comeals-monorepo', 'BACKUP' => 'b245', 'HEROKU_API_KEY' => 'test-key' })
    end

    # No job of the new code may run on the restored database, so the
    # worker stops with web, and the restore waits for both.
    it 'turns maintenance on, captures, stops web and the worker, waits for them, then restores' do
      result = restore

      expect(result.exitstatus).to eq(0)
      expect(result.outputs).to eq('web_count' => '2')
      expect(heroku_calls).to eq(
        ["heroku maintenance:on #{prod}", "heroku pg:backups:capture #{prod}",
         "heroku ps:scale web=0 worker=0 #{prod}", "heroku ps #{prod} --json", "heroku ps #{prod} --json",
         "heroku pg:backups:restore b245 DATABASE_URL #{prod} --confirm comeals-monorepo"]
      )
      expect(sandbox.calls_to('sleep').map(&:args)).to eq([['5']])
      expect(result.out).to include('comeals-monorepo runs 2 web dyno(s) and a worker dyno. Scaling both to 0.')
    end

    # A release from before the worker dyno has no worker process type,
    # and Heroku refuses to scale one.
    it 'stops only web when the running release has no worker process type' do
      sandbox.rule('curl', '* https://api.heroku.com/apps/comeals-monorepo/formation',
                   out: '[{"type":"web","quantity":2}]')

      result = restore

      expect(result.exitstatus).to eq(0)
      expect(heroku_calls.grep(/ps:scale/)).to eq(["heroku ps:scale web=0 #{prod}"])
      expect(result.out).to include('comeals-monorepo runs 2 web dyno(s) and no worker dyno. Scaling web to 0.')
    end

    # Production state: maintenance on, web at 0, the database as the new
    # code left it. The step that says what to do by hand runs next.
    it 'does not restore when a web or worker dyno still runs after 3 minutes' do
      sandbox.rule('heroku', "ps #{prod} --json", out: '[{"type":"worker"}]')

      result = restore

      expect(result.exitstatus).to eq(1)
      expect(result.out).to include('A web or worker dyno still runs 3 minutes after they were scaled to 0')
      expect(heroku_calls.grep(/restore/)).to be_empty
      expect(sandbox.calls_to('sleep').map(&:args).size).to eq(35)
    end

    # Production state: maintenance on, web still up on the new code, the
    # database unchanged.
    it 'stops before web is scaled when the formation cannot be read' do
      sandbox.rule('curl', '* https://api.heroku.com/apps/comeals-monorepo/formation', exit: 22)

      result = restore

      expect(result.exitstatus).not_to eq(0)
      expect(heroku_calls).to eq(["heroku maintenance:on #{prod}", "heroku pg:backups:capture #{prod}"])
    end

    it 'fails when the restore fails' do
      sandbox.rule('heroku', 'pg:backups:restore *', err: 'restore failed', exit: 1)

      expect(restore.exitstatus).to eq(1)
    end
  end

  describe 'bin/lib/rollback/roll-back' do
    before do
      sandbox.rule('heroku', "rollback v612 #{prod}")
      sandbox.rule('heroku', "ps:scale worker=1 #{prod}")
      sandbox.rule('heroku', "ps:scale worker=0 #{prod}")
      sandbox.rule('heroku', "ps:scale #{prod}", out: "web=1:Basic worker=1:Basic\n")
      sandbox.rule('heroku', "releases #{prod} --json", out: '[{"status":"succeeded"}]')
      sandbox.rule('heroku', "config:get HEROKU_SLUG_COMMIT #{prod}", out: "#{good}\n")
      sandbox.rule('sleep')
    end

    def roll(target_has_worker: 'true')
      sandbox.run_script('bin/lib/rollback/roll-back',
                         env: { 'APP' => 'comeals-monorepo', 'TARGET' => 'v612', 'BAD_SHA' => bad,
                                'TARGET_HAS_WORKER' => target_has_worker })
    end

    it 'rolls back, waits for the release phase, and checks the commit changed' do
      sandbox.rule('heroku', "releases #{prod} --json", out: '[{"status":"pending"}]', once: true)

      result = roll

      expect(result.exitstatus).to eq(0)
      expect(result.outputs).to eq('bad_sha' => bad, 'live_sha' => good)
      expect(result.out).to include("comeals-monorepo now runs #{good}.")
      expect(heroku_calls.first).to eq("heroku rollback v612 #{prod}")
      expect(sandbox.calls_to('sleep').map(&:args)).to eq([['5']])
    end

    # After a restore the worker is at 0, and a release that was at 0
    # stays at 0 through a rollback. The release it goes back to runs its
    # jobs on the worker dyno, so the worker starts once its code runs.
    it 'starts the worker once the old code runs, when that release has a worker dyno' do
      result = roll

      expect(result.exitstatus).to eq(0)
      expect(heroku_calls.last).to eq("heroku ps:scale worker=1 #{prod}")
      expect(heroku_calls.grep(/worker=0/)).to be_empty
    end

    # The old code runs no Solid Queue. The new code's jobs must not go on
    # running beside it, and after the rollback Heroku would refuse to
    # scale a process type the release does not have.
    it 'stops the worker before the rollback when the release it goes back to has none' do
      result = roll(target_has_worker: 'false')

      expect(result.exitstatus).to eq(0)
      expect(heroku_calls.first(3))
        .to eq(["heroku ps:scale #{prod}", "heroku ps:scale worker=0 #{prod}", "heroku rollback v612 #{prod}"])
      expect(heroku_calls.grep(/worker=1/)).to be_empty
      expect(result.out).to include("v612 has no worker dyno, so the worker stays at 0.\n")
    end

    it 'scales no worker when neither release has one' do
      sandbox.rule('heroku', "ps:scale #{prod}", out: "web=1:Basic\n")

      result = roll(target_has_worker: 'false')

      expect(result.exitstatus).to eq(0)
      expect(heroku_calls.grep(/ps:scale/)).to eq(["heroku ps:scale #{prod}"])
    end

    it 'stops and shows the output when the release phase fails' do
      sandbox.rule('heroku', "releases #{prod} --json", out: '[{"status":"failed"}]')
      sandbox.rule('heroku', "releases:output #{prod}", out: "line\n" * 40)

      result = roll

      expect(result.exitstatus).to eq(1)
      expect(result.out).to include('The release phase of the rollback did not succeed (status: failed)')
      expect(result.out.lines.count("line\n")).to eq(30)
      expect(result.outputs).to be_empty
      expect(heroku_calls.grep(/ps:scale/)).to be_empty
    end

    it 'still fails with its message when the release output cannot be read' do
      sandbox.rule('heroku', "releases #{prod} --json", out: '[{"status":"failed"}]')
      sandbox.rule('heroku', "releases:output #{prod}", exit: 1)

      result = roll

      expect(result.exitstatus).to eq(1)
      expect(result.out).to include('did not succeed (status: failed)')
    end

    it 'stops waiting after 36 tries' do
      sandbox.rule('heroku', "releases #{prod} --json", out: '[{"status":"pending"}]')
      sandbox.rule('heroku', "releases:output #{prod}")

      result = roll

      expect(result.exitstatus).to eq(1)
      expect(result.out).to include('(status: pending)')
      expect(heroku_calls.grep(/releases -a/).size).to eq(36)
      expect(sandbox.calls_to('sleep').map(&:args).size).to eq(35)
    end

    it 'fails when the running commit did not change' do
      sandbox.rule('heroku', "config:get HEROKU_SLUG_COMMIT #{prod}", out: "#{bad}\n")

      result = roll

      expect(result.exitstatus).to eq(1)
      expect(result.out).to include('Rollback did not change the running slug.')
      expect(result.outputs).to eq('bad_sha' => bad, 'live_sha' => bad)
      expect(heroku_calls.grep(/ps:scale/)).to be_empty
    end

    it 'fails when heroku rollback fails' do
      sandbox.rule('heroku', "rollback v612 #{prod}", exit: 1)

      expect(roll.exitstatus).to eq(1)
      expect(heroku_calls).to eq(["heroku rollback v612 #{prod}"])
    end
  end

  describe 'bin/lib/rollback/start-web' do
    before do
      sandbox.rule('heroku', "ps:scale web=2 #{prod}")
      sandbox.rule('heroku', "ps #{prod} --json", out: '[{"type":"web","state":"up"},{"type":"web","state":"up"}]')
      sandbox.rule('heroku', "ps #{prod} --json",
                   out: '[{"type":"web","state":"up"},{"type":"web","state":"starting"},{"type":"run","state":"up"}]',
                   once: true)
      sandbox.rule('sleep')
    end

    def start
      sandbox.run_script('bin/lib/rollback/start-web', env: { 'APP' => 'comeals-monorepo', 'WEB_COUNT' => '2' })
    end

    it 'scales web back and waits until every web dyno is up' do
      result = start

      expect(result.exitstatus).to eq(0)
      expect(result.out).to include('2 web dyno(s) up.')
      expect(heroku_calls.first).to eq("heroku ps:scale web=2 #{prod}")
      expect(sandbox.calls_to('sleep').map(&:args)).to eq([['5']])
    end

    it 'fails when the web dynos are not up after 3 minutes' do
      sandbox.rule('heroku', "ps #{prod} --json", out: '[{"type":"web","state":"up"},{"type":"web","state":"crashed"}]')

      result = start

      expect(result.exitstatus).to eq(1)
      expect(result.out).to include('Web was scaled to 2, but only 1 web dyno(s) are up after 3 minutes.')
      expect(sandbox.calls_to('sleep').map(&:args).size).to eq(35)
    end
  end

  describe 'bin/lib/rollback/say-what-to-do' do
    def say(restore: 'success', roll: 'success', start: 'skipped', web_count: '2', target_has_worker: 'true')
      sandbox.run_script('bin/lib/rollback/say-what-to-do',
                         env: { 'RESTORE' => restore, 'ROLL' => roll, 'START' => start, 'WEB_COUNT' => web_count,
                                'TARGET' => 'v612', 'URL' => 'https://comeals.com', 'APP' => 'comeals-monorepo',
                                'BACKUP' => 'b245', 'TARGET_HAS_WORKER' => target_has_worker })
    end

    it 'says only maintenance may be on when web was started' do
      result = say(start: 'success')

      expect(result.exitstatus).to eq(0)
      expect(result.out).to include("Only maintenance mode\nmay still be on.")
      expect(result.out).to include('  heroku maintenance:off -a comeals-monorepo')
      expect(result.out).not_to include('ps:scale')
    end

    it 'gives the restore, the rollback and the restart when the restore step failed' do
      result = say(restore: 'failure', roll: 'skipped')

      expect(result.exitstatus).to eq(0)
      expect(result.out).to include('Maintenance mode is on. Web and the worker may be at 0')
      expect(result.out).to include("  heroku ps:scale web=0 -a comeals-monorepo\n  " \
                                    "heroku ps:scale worker=0 -a comeals-monorepo   (when heroku ps lists a worker)\n")
      expect(result.out)
        .to include('  heroku pg:backups:restore b245 DATABASE_URL -a comeals-monorepo --confirm comeals-monorepo')
      expect(result.out).to include('  heroku rollback v612 -a comeals-monorepo')
      expect(result.out).to include("  heroku ps:scale worker=1 -a comeals-monorepo\n  " \
                                    'heroku ps:scale web=2 -a comeals-monorepo')
    end

    it 'says to leave the worker at 0 when the release it goes back to has none' do
      result = say(roll: 'failure', target_has_worker: 'false')

      expect(result.out).to include('  (v612 has no worker dyno: leave the worker at 0)')
      expect(result.out).not_to include('worker=1')
    end

    it 'gives the rollback and the restart when the rollback failed' do
      result = say(roll: 'failure')

      expect(result.out).to include('The backup is restored, but the old code may not run yet.')
      expect(result.out).not_to include('pg:backups:restore')
      expect(result.out).to include('  heroku rollback v612 -a comeals-monorepo')
      expect(result.out).to include('  heroku ps:scale web=2 -a comeals-monorepo')
    end

    it 'gives only the restart when the start step failed' do
      result = say(start: 'failure')

      expect(result.out).not_to include('heroku rollback')
      expect(result.out).to include('  heroku ps:scale web=2 -a comeals-monorepo')
      expect(result.out).to include('  bin/smoke https://comeals.com')
    end

    it 'restarts one web dyno when the restore stopped before it counted them' do
      result = say(restore: 'failure', web_count: '')

      expect(result.out).to include('  heroku ps:scale web=1 -a comeals-monorepo')
    end
  end

  describe 'bin/lib/rollback/mark-release-notes' do
    before do
      sandbox.rule('gh', 'release list --limit 20 --json tagName --jq *',
                   out: "deploy-20261012-1200\ndeploy-20261005-1200\nold-tag\n")
      sandbox.rule('gh', 'api repos/{owner}/{repo}/commits/deploy-20261012-1200 --jq .sha', out: "#{good}\n")
      sandbox.rule('gh', 'api repos/{owner}/{repo}/commits/deploy-20261005-1200 --jq .sha', out: "#{bad}\n")
      sandbox.rule('gh', 'api repos/{owner}/{repo}/commits/old-tag --jq .sha', exit: 1)
      sandbox.rule('gh', 'release view deploy-20261005-1200 --json body --jq .body', out: "## What changed\n- A fix\n")
      sandbox.rule('gh', 'release edit deploy-20261005-1200 --notes-file new_body.md')
      sandbox.rule('date', '-u +%Y-%m-%d', out: "2026-10-19\n")
    end

    def mark(sha = bad)
      sandbox.run_script('bin/lib/rollback/mark-release-notes',
                         env: { 'BAD_SHA' => sha, 'REASON' => 'The bills page is blank' })
    end

    it 'puts the reason at the top of the release that pointed at the rolled-back commit' do
      result = mark

      expect(result.exitstatus).to eq(0)
      expect(result.out).to include('Marked release deploy-20261005-1200 as rolled back.')
      expect(sandbox.call_lines('gh').last).to eq('gh release edit deploy-20261005-1200 --notes-file new_body.md')
      expect(File.read(File.join(sandbox.root, 'new_body.md'))).to eq(
        "> **Rolled back on 2026-10-19** — The bills page is blank\n\n## What changed\n- A fix\n"
      )
    end

    it 'says so when no release points at the commit, reading past a tag it cannot resolve' do
      result = mark('d' * 40)

      expect(result.exitstatus).to eq(0)
      expect(result.out).to include("No GitHub release points at #{'d' * 40} — nothing to mark.")
      expect(sandbox.call_lines('gh').last).to eq('gh api repos/{owner}/{repo}/commits/old-tag --jq .sha')
    end
  end

  describe 'bin/lib/rollback/file-issue' do
    it 'files the follow-up issue with both commits and the reason' do
      sandbox.rule('gh', 'issue create *')
      sandbox.rule('date', '-u +%Y-%m-%d', out: "2026-10-19\n")

      result = sandbox.run_script('bin/lib/rollback/file-issue',
                                  env: { 'REASON' => 'The bills page is blank', 'BAD_SHA' => bad, 'LIVE_SHA' => good })

      expect(result.exitstatus).to eq(0)
      expect(sandbox.calls_to('gh').map(&:args).size).to eq(1)
      args = sandbox.calls_to('gh').map(&:args).first
      expect(args[0..3]).to eq(['issue', 'create', '--title', 'Production rolled back: The bills page is blank'])
      expect(args[4]).to eq('--body')
      expect(args[5]).to start_with("Production was rolled back from `#{bad}` to `#{good}` on 2026-10-19.\n\n" \
                                    "Reason: The bills page is blank\n\n")
      expect(args[5]).to end_with("- [ ] Clear the hold: `gh variable delete DEPLOY_HOLD`\n" \
                                  '- [ ] Check whether the bad version wrote data that needs correcting entries')
    end
  end

  # The Rollback workflow can run on staging, as a rehearsal. A step that
  # gets a GitHub token writes to GitHub (DEPLOY_HOLD, the release notes,
  # the follow-up issue), and the repository is public, so each one runs
  # only for production.
  describe '.github/workflows/rollback.yml' do
    let(:steps) do
      YAML.safe_load_file(Rails.root.join('.github/workflows/rollback.yml').to_s)['jobs']['rollback']['steps']
    end

    it 'runs every step that has a GitHub token only for production' do
      with_token = steps.select { it.dig('env', 'GH_TOKEN') }

      expect(with_token.pluck('name')).to eq(['Hold the weekly deploy', 'Mark the release notes',
                                              'File the follow-up issue'])
      expect(with_token.pluck('if')).to all(eq("inputs.app == 'comeals-monorepo'"))
    end

    it 'gives no other step a way to write to GitHub' do
      others = steps.reject { it.dig('env', 'GH_TOKEN') }

      expect(others.map { "#{it['run']}#{it['with']}" }.grep(/\bgh |github\.token/)).to eq([])
    end
  end
end
