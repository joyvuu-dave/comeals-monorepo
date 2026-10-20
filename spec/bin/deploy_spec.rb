# frozen_string_literal: true

require 'rails_helper'
require 'shellwords'
require_relative 'deploy_fakes/deploy_harness'

# bin/deploy, run for real against fake heroku, git remotes, gh, curl,
# bundle, npm, sleep and bin/smoke (spec/bin/deploy_fakes). Each failure
# example says what production is left in, because that is what the
# person running the deploy needs to know next.
#
# Every run happens under bashcov, and the after(:context) hook holds
# bin/deploy and bin/lib/output.sh at 100% of their lines.
RSpec.describe 'bin/deploy', bash_coverage: BashCoverage.new('spec/bin/deploy_spec.rb') do
  let(:deploy) { DeployHarness.new(self.class.metadata[:bash_coverage]) }
  let(:head) { deploy.commits[:head] }
  let(:recovery_banner) { 'DEPLOY FAILED — MANUAL RECOVERY REQUIRED' }

  after { deploy.cleanup }

  # This runs only when every example in the file ran, so one example on
  # its own (rspec spec/bin/deploy_spec.rb:42) can still pass. bin/check and
  # CI run the whole suite, so there it always runs.
  after(:context) do
    ran_all = self.class.descendant_filtered_examples.size == self.class.descendants.sum { it.examples.size }
    self.class.metadata[:bash_coverage].check! if ran_all
  end

  # Production as the run left it. `pushed` is true when the new code
  # reached Heroku.
  def expect_production(maintenance:, web:, pushed:)
    expect(deploy.state).to include(maintenance:, web:, pushed: pushed ? head : nil)
  end

  def expect_nothing_changed_in_production
    expect_production(maintenance: false, web: 1, pushed: false)
    expect(deploy.state[:backups]).to eq(0)
    expect(deploy.calls_to('heroku').grep(/maintenance|ps:scale|pg:backups:capture|run /)).to eq([])
  end

  describe 'a push deploy (no migration changed)' do
    it 'pushes, checks the release, clears the cache, recalculates, checks the site, and says so' do
      result = deploy.run('--yes')

      expect(result.status).to eq(0)
      expect(result.output).to include('No migration changes — push deploy', 'PUSH deploy (no migrations)',
                                       'Proceeding without a prompt (--yes)', 'Release phase succeeded',
                                       'Cache flushed', 'Billing recalculated', 'Smoke test passed',
                                       'Deploy complete!')
      expect_production(maintenance: false, web: 1, pushed: true)
      expect(deploy.state[:backups]).to eq(1)
      expect(deploy.calls_to('heroku').grep(/maintenance|ps:scale/)).to eq([])
      expect(deploy.calls).to include(
        'heroku run --exit-code bin/rails runner Rails.cache.clear -a comeals-monorepo',
        'heroku run --exit-code bin/rake billing:recalculate -a comeals-monorepo',
        'heroku run --exit-code bin/rake deploy:verify_solid_queue -a comeals-monorepo',
        'smoke https://comeals.com'
      )
      expect(deploy.calls_to('curl').map { it.split.last }).to eq(
        %w[https://comeals.com https://comeals.com/api/v1/version https://www.comeals.com
           https://admin.comeals.com https://api.comeals.com https://comeals-monorepo-b68ce4e5c3d4.herokuapp.com]
      )
    end

    # Some data-fix migrations write what they deleted only to the release
    # phase output. The person running the deploy keeps this file.
    it 'saves the release phase output to a file under tmp/deploy and prints its path' do
      result = deploy.run('--yes')

      files = Dir[File.join(deploy.repo, 'tmp/deploy/release-output-*.txt')]
      expect(files.size).to eq(1)
      expect(File.basename(files.first)).to match(/\Arelease-output-\d{8}T\d{6}Z\.txt\z/)
      expect(File.read(files.first)).to eq("Running release command... migrating\n")
      path = files.first.delete_prefix("#{deploy.repo}/")
      expect(result.output).to include("Release phase output saved to #{path} (keep this file)")
      expect(deploy.calls).to include('heroku releases:output -a comeals-monorepo')
    end

    # The release already ran, so the deploy goes on. The warning says how
    # to save the output by hand.
    it 'warns and goes on when it cannot read the release phase output' do
      deploy.rule('heroku', '^releases:output', exit: 1, stderr: "releases:output failed\n")

      result = deploy.run('--yes')

      expect(result.status).to eq(0)
      path = Dir[File.join(deploy.repo, 'tmp/deploy/release-output-*.txt')].first.delete_prefix("#{deploy.repo}/")
      expect(result.output).to include(
        'Could not read the release phase output. Save it by hand now:',
        "heroku releases:output -a comeals-monorepo > #{path}",
        'Release phase succeeded', 'Deploy complete!'
      )
      expect(result.output).not_to include('Release phase output saved')
      expect_production(maintenance: false, web: 1, pushed: true)
    end

    it 'takes the backup before it pushes' do
      deploy.run('--yes')

      order = deploy.calls.map { it.split.first(2).join(' ') }
      expect(order.index('heroku pg:backups:capture')).to be < order.index('git push')
    end
  end

  describe 'a maintenance deploy (a migration changed)' do
    before { deploy.production(heroku_sha: deploy.commits[:first_migration]) }

    it 'lists the migration, turns maintenance on, scales web to 0, pushes, and brings everything back' do
      result = deploy.run('--yes')

      expect(result.status).to eq(0)
      expect(result.output).to include('Migration changes detected — maintenance deploy required:',
                                       'db/migrate/20260201000000_second.rb',
                                       'MAINTENANCE deploy (has migrations)', 'Deploy complete!')
      expect(result.output).not_to include(recovery_banner)
      expect_production(maintenance: false, web: 1, pushed: true)
      steps = deploy.calls_to('heroku').grep(/maintenance|ps:scale|releases|cache\.clear|billing/)
                    .map { it.delete_suffix(' -a comeals-monorepo').delete_suffix(' --json') }
      expect(steps).to eq([
                            'heroku maintenance:on', 'heroku ps:scale web=0', 'heroku releases -a comeals-monorepo',
                            'heroku releases:output',
                            'heroku run --exit-code bin/rails runner Rails.cache.clear',
                            'heroku run --exit-code bin/rake billing:recalculate',
                            'heroku ps:scale web=1', 'heroku maintenance:off'
                          ])
      push = deploy.calls.index('git push heroku main --force')
      expect(push).to be > deploy.calls.index('heroku ps:scale web=0 -a comeals-monorepo')
    end

    it 'uses maintenance when it cannot read the commit Heroku runs' do
      deploy.production(heroku_sha: '')

      result = deploy.run('--yes')

      expect(result.output).to include('Cannot read Heroku SHA (first deploy or endpoint unreachable)',
                                       'Will deploy with maintenance mode for safety',
                                       'MAINTENANCE deploy (has migrations)')
      expect(deploy.calls).to include('heroku maintenance:on -a comeals-monorepo')
      expect_production(maintenance: false, web: 1, pushed: true)
    end
  end

  describe 'the commit Heroku runs is not in the local history' do
    it 'fetches it from Heroku and compares migrations as usual' do
      sha, side = deploy.commit_elsewhere('app/a.rb' => 'elsewhere')
      deploy.production(heroku_sha: sha)
      deploy.rule('git', '^fetch heroku main', exec: [deploy.real_git, 'fetch', '-q', side, 'main'])

      result = deploy.run('--yes')

      expect(result.output).to include('Heroku SHA not in local history — fetching from Heroku...',
                                       'Fetched Heroku main branch', 'No migration changes — push deploy')
      expect(deploy.calls).to include('git fetch heroku main --quiet')
      expect(result.status).to eq(0)
    end

    it 'uses maintenance when the fetch fails' do
      deploy.production(heroku_sha: 'a' * 40)
      deploy.rule('git', '^fetch heroku', exit: 128, stderr: "fatal: unable to access heroku\n")

      result = deploy.run('--yes')

      expect(result.output).to include('Cannot fetch from Heroku — assuming migrations needed',
                                       'MAINTENANCE deploy (has migrations)')
      expect(result.status).to eq(0)
    end

    it 'uses maintenance when the fetch works but the commit is still missing' do
      deploy.production(heroku_sha: 'a' * 40)
      deploy.rule('git', '^fetch heroku', stdout: '')

      result = deploy.run('--yes')

      expect(result.output).to include('Heroku SHA still not in object store — assuming migrations needed',
                                       'MAINTENANCE deploy (has migrations)')
      expect(result.status).to eq(0)
    end
  end

  it 'uses maintenance when git diff fails' do
    # A blob, not a commit: git cat-file -e finds it, git diff refuses it.
    blob = deploy.git('hash-object', '-w', '--stdin')
    deploy.production(heroku_sha: blob)

    result = deploy.run('--yes')

    expect(result.output).to include('git diff failed — assuming migrations needed', 'MAINTENANCE deploy')
    expect(result.status).to eq(0)
  end

  it 'deploys nothing when Heroku already runs this commit' do
    deploy.production(heroku_sha: deploy.commits[:head])

    result = deploy.run('--yes')

    expect(result.status).to eq(0)
    expect(result.output).to include('Already up to date', 'Already up to date — nothing to deploy.')
    expect(deploy.calls_to('bundle')).to eq([])
    expect_nothing_changed_in_production
  end

  describe 'pre-flight refusals, before anything in production changes' do
    it 'refuses without the heroku CLI' do
      deploy.uninstall('heroku')

      result = deploy.run('--yes')

      expect(result.status).to eq(1)
      expect(result.output).to include('heroku CLI not found in PATH')
      expect(deploy.calls).to eq([])
    end

    it 'refuses when not logged in to Heroku' do
      deploy.rule('heroku', '^auth:whoami', exit: 1)

      result = deploy.run('--yes')

      expect(result.status).to eq(1)
      expect(result.output).to include('Not logged into Heroku (run: heroku login)')
      expect_nothing_changed_in_production
    end

    it 'refuses without a heroku git remote' do
      deploy.git('remote', 'remove', 'heroku')

      result = deploy.run('--yes')

      expect(result.status).to eq(1)
      expect(result.output).to include("No 'heroku' git remote", 'Run: heroku git:remote -a comeals-monorepo')
      expect_nothing_changed_in_production
    end

    it 'refuses on a branch other than main' do
      deploy.git('checkout', '-q', '-b', 'feature')

      result = deploy.run('--yes')

      expect(result.status).to eq(1)
      expect(result.output).to include("On branch 'feature', expected 'main'")
      expect_nothing_changed_in_production
    end

    it 'refuses with uncommitted changes, and lists them' do
      File.write(File.join(deploy.repo, 'stray.txt'), 'x')

      result = deploy.run('--yes')

      expect(result.status).to eq(1)
      expect(result.output).to include('Uncommitted changes detected:', '?? stray.txt')
      expect_nothing_changed_in_production
    end

    it 'refuses with commits that are not pushed to origin' do
      deploy.git('update-ref', 'refs/remotes/origin/main', deploy.commits[:second_migration])

      result = deploy.run('--yes')

      expect(result.status).to eq(1)
      expect(result.output).to include('1 unpushed commit(s) on main')
      expect_nothing_changed_in_production
    end

    it 'pulls when origin has newer commits, then goes on' do
      newer = deploy.commit({ 'app/b.rb' => 'newer' }, 'newer')
      deploy.git('reset', '-q', '--hard', head)
      deploy.git('update-ref', 'refs/remotes/origin/main', newer)

      result = deploy.run('--yes')

      expect(result.output).to include('Local is 1 commit(s) behind origin/main, pulling...', 'Pulled 1 commit(s)')
      expect(deploy.calls).to include('git pull --ff-only --quiet')
      expect(result.status).to eq(0)
    end

    it 'stops when a local check fails (RuboCop here)' do
      deploy.rule('bundle', '^exec rubocop', exit: 1, stdout: "1 offense detected\n")

      result = deploy.run('--yes')

      expect(result.status).to eq(1)
      expect(result.output).to include('Running RuboCop...', '1 offense detected')
      expect(result.output).not_to include('RuboCop passed')
      expect_nothing_changed_in_production
    end
  end

  describe 'the CI gate' do
    it 'refuses without the gh CLI' do
      deploy.uninstall('gh')

      result = deploy.run('--yes')

      expect(result.status).to eq(1)
      expect(result.output).to include('gh CLI not found — needed to read CI status (DEPLOY_WITHOUT_CI=1 overrides)')
      expect_nothing_changed_in_production
    end

    it 'refuses when GitHub cannot be read' do
      deploy.rule('gh', '^api', exit: 1, stderr: "HTTP 502\n")

      result = deploy.run('--yes')

      expect(result.status).to eq(1)
      expect(result.output).to include('Could not read check runs from GitHub (DEPLOY_WITHOUT_CI=1 overrides)')
      expect_nothing_changed_in_production
    end

    it 'asks about the commit it would ship' do
      deploy.run('--yes')

      expect(deploy.calls_to('gh').first).to include("repos/{owner}/{repo}/commits/#{head}/check-runs")
    end

    it 'refuses a commit with no CI runs' do
      deploy.set(check_runs: '')

      result = deploy.run('--yes')

      expect(result.status).to eq(1)
      expect(result.output).to include("No CI runs found for #{head[0, 7]} — push and let CI finish before deploying")
      expect_nothing_changed_in_production
    end

    it 'refuses a run that is still going and a run that failed, and names both' do
      deploy.set(check_runs: "test|completed|success\ne2e|in_progress|pending\nlint|completed|failure\n" \
                             "visual|completed|neutral\nstorm|completed|skipped\n")

      result = deploy.run('--yes')

      expect(result.status).to eq(1)
      expect(result.output).to include('still running: e2e', 'failure: lint',
                                       "CI is not green for #{head[0, 7]}. Fix or wait, then deploy.")
      expect(result.output).not_to include('visual', 'storm')
      expect_nothing_changed_in_production
    end

    it 'counts neutral and skipped runs as green' do
      deploy.set(check_runs: "test|completed|success\nvisual|completed|neutral\nstorm|completed|skipped\n")

      result = deploy.run('--yes')

      expect(result.output).to include("All CI checks green for #{head[0, 7]}")
      expect(result.status).to eq(0)
    end
  end

  describe 'DEPLOY_WITHOUT_CI=1 (the break-glass)' do
    let(:break_glass) { { 'DEPLOY_WITHOUT_CI' => '1' } }

    it 'refuses without a terminal to type the phrase on' do
      result = deploy.run('--yes', env: break_glass, input: "break glass\n")

      expect(result.status).to eq(1)
      expect(result.output).to include('DEPLOY_WITHOUT_CI=1 — the break-glass. Every CI result will be ignored.',
                                       'The break-glass needs a terminal to type the confirmation phrase.')
      expect_nothing_changed_in_production
    end

    it 'stops when the phrase is wrong' do
      result = deploy.run('--yes', env: break_glass, input: "yes\n", tty: true)

      expect(result.status).to eq(1)
      expect(result.output).to include("Type 'break glass' to continue: ", 'Aborted.')
      expect_nothing_changed_in_production
    end

    it 'skips CI, files a follow-up issue, and deploys' do
      deploy.rule('gh', '^issue create', exit: 0, stdout: "https://github.com/example/comeals/issues/1\n")

      result = deploy.run('--yes', env: break_glass, input: "break glass\n", tty: true)

      expect(result.status).to eq(0)
      expect(result.output).to include('Follow-up issue filed', 'Deploy complete!')
      expect(deploy.calls_to('gh').grep(/^gh api/)).to eq([])
      issue = deploy.calls_to('gh').sole
      today = Time.now.utc.strftime('%Y-%m-%d')
      expect(issue).to include("--title Break-glass deploy on #{today}",
                               "bin/deploy ran with DEPLOY_WITHOUT_CI=1 on #{today} at commit #{head}.")
    end

    it 'goes on and asks for an issue by hand when it cannot file one' do
      deploy.rule('gh', '^issue create', exit: 1)

      result = deploy.run('--yes', env: break_glass, input: "break glass\n", tty: true)

      expect(result.output).to include('Could not file the follow-up issue (GitHub down?) — file one by hand')
      expect(result.status).to eq(0)
    end

    it 'goes on and asks for an issue by hand without the gh CLI' do
      deploy.uninstall('gh')

      result = deploy.run('--yes', env: break_glass, input: "break glass\n", tty: true)

      expect(result.output).to include('Could not file the follow-up issue (GitHub down?) — file one by hand')
      expect(result.status).to eq(0)
    end
  end

  describe 'the Solid Queue config vars' do
    it 'sets RAILS_DB_POOL=4 and SOLID_QUEUE_IN_PUMA=true when they are missing, after the question' do
      deploy.production(config: {})

      result = deploy.run('--yes')

      expect(result.output).to include(
        "RAILS_DB_POOL='' and SOLID_QUEUE_IN_PUMA='' — the deploy will set RAILS_DB_POOL=4 and " \
        'SOLID_QUEUE_IN_PUMA=true first',
        'first: heroku config:set RAILS_DB_POOL=4 SOLID_QUEUE_IN_PUMA=true',
        'RAILS_DB_POOL=4 and SOLID_QUEUE_IN_PUMA=true set (one dyno restart)'
      )
      expect(deploy.state[:config]).to eq('RAILS_DB_POOL' => '4', 'SOLID_QUEUE_IN_PUMA' => 'true')
      order = deploy.calls.map { it.split.first(2).join(' ') }
      expect(order.index('heroku config:set')).to be < order.index('heroku pg:backups:capture')
      expect(result.status).to eq(0)
    end

    it 'sets them when the pool is below 4' do
      deploy.production(config: { 'RAILS_DB_POOL' => '2', 'SOLID_QUEUE_IN_PUMA' => 'true' })

      result = deploy.run('--yes')

      expect(result.output).to include("RAILS_DB_POOL='2' and SOLID_QUEUE_IN_PUMA='true'")
      expect(deploy.state[:config]['RAILS_DB_POOL']).to eq('4')
    end

    it 'sets them when the pool is not a number' do
      deploy.production(config: { 'RAILS_DB_POOL' => 'four', 'SOLID_QUEUE_IN_PUMA' => 'true' })

      deploy.run('--yes')

      expect(deploy.state[:config]['RAILS_DB_POOL']).to eq('4')
    end

    it 'sets them when Heroku cannot be asked' do
      deploy.rule('heroku', '^config:get', exit: 1)

      deploy.run('--yes')

      expect(deploy.calls).to include('heroku config:set RAILS_DB_POOL=4 SOLID_QUEUE_IN_PUMA=true -a comeals-monorepo')
    end

    it 'does not set them when they are there' do
      result = deploy.run('--yes')

      expect(result.output).to include('RAILS_DB_POOL=4, SOLID_QUEUE_IN_PUMA=true')
      expect(deploy.calls_to('heroku').grep(/config:set/)).to eq([])
    end

    # State left: no maintenance, web at 1, old code, no backup. Next step:
    # read the heroku error and run the deploy again.
    it 'stops before the backup when setting them fails' do
      deploy.production(config: {})
      deploy.rule('heroku', '^config:set', exit: 1, stderr: "config:set failed\n")

      result = deploy.run('--yes')

      expect(result.status).to eq(1)
      expect(result.output).to include('config:set failed')
      expect(result.output).not_to include(recovery_banner)
      expect_nothing_changed_in_production
    end
  end

  describe 'the question before the deploy' do
    it 'stops on anything but y, and changes nothing' do
      result = deploy.run(input: "n\n")

      expect(result.status).to eq(0)
      expect(result.output).to include('Continue? (y/n) ', 'Aborted.')
      expect_nothing_changed_in_production
    end

    it 'goes on with y' do
      result = deploy.run(input: "y\n")

      expect(result.output).to include('Deploy complete!')
      expect(result.status).to eq(0)
    end

    it 'goes on with Y' do
      result = deploy.run(input: "Y\n")

      expect(result.output).to include('Deploy complete!')
    end

    it 'does not ask with DEPLOY_YES=1' do
      result = deploy.run(env: { 'DEPLOY_YES' => '1' })

      expect(result.output).to include('Proceeding without a prompt (--yes)', 'Deploy complete!')
      expect(result.output).not_to include('Continue?')
    end
  end

  describe 'the backup' do
    # State left: no maintenance, web at 1, old code. Next step: read the
    # heroku error and run the deploy again.
    it 'stops before any push when the backup fails' do
      deploy.rule('heroku', '^pg:backups:capture', exit: 1, stderr: "backup failed\n")

      result = deploy.run('--yes')

      expect(result.status).to eq(1)
      expect(result.output).to include('backup failed')
      expect(result.output).not_to include('Backup complete', recovery_banner)
      expect(deploy.calls_to('git').grep(/push/)).to eq([])
      expect_production(maintenance: false, web: 1, pushed: false)
    end

    it 'prints the backup id' do
      result = deploy.run('--yes')

      expect(result.output).to include('Backup complete', '=== Backup b001')
    end

    it 'goes on when the backup info cannot be read' do
      deploy.rule('heroku', '^pg:backups:info', exit: 1, stdout: "info failed\n")

      result = deploy.run('--yes')

      expect(result.output).to include('info failed', 'Deploy complete!')
    end
  end

  describe 'failures during a push deploy' do
    # State left: no maintenance, web at 1, old code still running. Next
    # step: fix the push problem and run the deploy again.
    it 'stops when the push fails, and production keeps the old code' do
      deploy.rule('git', '^push heroku', exit: 1, stderr: "remote: Build failed\n")

      result = deploy.run('--yes')

      expect(result.status).to eq(1)
      expect(result.output).to include('Pushing main to Heroku...', 'remote: Build failed')
      expect(result.output).not_to include('Code pushed', recovery_banner)
      expect_production(maintenance: false, web: 1, pushed: false)
    end

    # Heroku does not start a release whose release phase failed, so the
    # old code keeps running. State left: no maintenance, web at 1.
    it 'stops when the release phase fails, and prints its output' do
      deploy.production(releases: %w[failed])

      result = deploy.run('--yes')

      expect(result.status).to eq(1)
      expect(result.output).to include('The release phase did not succeed (status: failed). Its output:',
                                       'Running release command... migrating')
      expect(result.output).not_to include('Maintenance stays on', recovery_banner, 'Cache flushed')
      expect(deploy.calls).to include('heroku releases:output -a comeals-monorepo')
      expect_production(maintenance: false, web: 1, pushed: true)
    end

    it 'waits while the release is pending' do
      deploy.production(releases: %w[pending pending succeeded])

      result = deploy.run('--yes')

      expect(result.output).to include('Release phase succeeded', 'Deploy complete!')
      expect(deploy.calls_to('heroku').grep(/releases -a/).size).to eq(3)
      expect(deploy.calls_to('sleep').first(2)).to eq(['sleep 5', 'sleep 5'])
    end

    # State left: no maintenance, web at 1, the release may still finish
    # later. Next step: heroku releases -a comeals-monorepo, and read the
    # release output once it is done.
    it 'gives up after 36 checks of a release that stays pending' do
      deploy.production(releases: ['pending'] * 40)

      result = deploy.run('--yes')

      expect(result.status).to eq(1)
      expect(result.output).to include('The release phase did not succeed (status: pending). Its output:')
      expect(deploy.calls_to('heroku').grep(/releases -a/).size).to eq(36)
      expect(deploy.calls_to('sleep')).to eq(['sleep 5'] * 36)
    end

    # The script stops with Python's error and no line of its own. The code
    # is pushed; the release may have worked. Next step: heroku releases.
    it 'stops with no message of its own when Heroku cannot list the releases' do
      deploy.rule('heroku', '^releases -a', exit: 1, stderr: "releases failed\n")

      result = deploy.run('--yes')

      expect(result.status).to eq(1)
      expect(result.output).to include('releases failed', 'JSONDecodeError')
      expect(result.output).not_to include('release phase did not succeed', recovery_banner)
      expect_production(maintenance: false, web: 1, pushed: true)
    end

    it 'warns and goes on when the cache clear and the recalculation fail' do
      deploy.rule('heroku', '^run --exit-code bin/(rails runner|rake billing)', exit: 1)

      result = deploy.run('--yes')

      expect(result.output).to include(
        'Cache flush failed — stale entries may persist until naturally invalidated',
        'billing:recalculate failed — balances may be stale until next daily run',
        'Deploy complete!'
      )
      expect(result.status).to eq(0)
    end
  end

  describe 'failures during a maintenance deploy' do
    before { deploy.production(heroku_sha: deploy.commits[:first_migration]) }

    def expect_recovery_banner(result)
      expect(result.output).to include(recovery_banner, 'App may still be in maintenance mode.',
                                       'Web dynos may be scaled to 0.',
                                       'heroku ps:scale web=1 -a comeals-monorepo',
                                       'heroku maintenance:off -a comeals-monorepo')
    end

    # State left: no maintenance, web at 1, old code. The banner does not
    # print, because the script never saw maintenance turn on.
    it 'stops when maintenance cannot be turned on' do
      deploy.rule('heroku', '^maintenance:on', exit: 1, stderr: "maintenance failed\n")

      result = deploy.run('--yes')

      expect(result.status).to eq(1)
      expect(result.output).to include('maintenance failed')
      expect(result.output).not_to include(recovery_banner)
      expect_production(maintenance: false, web: 1, pushed: false)
    end

    # State left: maintenance on, web at 1, old code. Next step: the two
    # commands the banner prints.
    it 'stops with the recovery banner when web cannot be scaled to 0' do
      deploy.rule('heroku', '^ps:scale web=0', exit: 1)

      result = deploy.run('--yes')

      expect(result.status).to eq(1)
      expect_recovery_banner(result)
      expect_production(maintenance: true, web: 1, pushed: false)
    end

    # State left: maintenance on, web at 0, old code, no migration ran.
    # Next step: the two commands the banner prints.
    it 'stops with the recovery banner when the push fails' do
      deploy.rule('git', '^push heroku', exit: 1, stderr: "remote: Build failed\n")

      result = deploy.run('--yes')

      expect(result.status).to eq(1)
      expect_recovery_banner(result)
      expect_production(maintenance: true, web: 0, pushed: false)
    end

    # State left: maintenance on, web at 0, new code pushed, migrations
    # maybe half run. Next step: read the release output, do not scale up
    # (docs/runbooks/undo-a-deploy.md).
    it 'keeps maintenance on and web at 0 when the release phase fails, and says why' do
      deploy.production(releases: %w[failed])

      result = deploy.run('--yes')

      expect(result.status).to eq(1)
      expect(result.output).to include(
        'The release phase did not succeed (status: failed). Its output:',
        'Maintenance stays on and web stays at 0. Do not scale web up until you know which migrations ran: ' \
        'the old code may not work on the new schema.'
      )
      expect_recovery_banner(result)
      expect(deploy.calls_to('heroku').grep(/run --exit-code/)).to eq([])
      expect_production(maintenance: true, web: 0, pushed: true)
    end

    # State left: maintenance on, web at 0, new code and migrations in.
    # Next step: the two commands the banner prints.
    it 'stops with the recovery banner when web cannot be scaled back up' do
      deploy.rule('heroku', '^ps:scale web=1', exit: 1)

      result = deploy.run('--yes')

      expect(result.status).to eq(1)
      expect_recovery_banner(result)
      expect_production(maintenance: true, web: 0, pushed: true)
    end

    # State left: maintenance on, web at 1, new code. Next step: heroku
    # maintenance:off.
    it 'stops with the recovery banner when maintenance cannot be turned off' do
      deploy.rule('heroku', '^maintenance:off', exit: 1)

      result = deploy.run('--yes')

      expect(result.status).to eq(1)
      expect_recovery_banner(result)
      expect_production(maintenance: true, web: 1, pushed: true)
    end
  end

  describe 'the log check' do
    it 'shows errors and warnings logged after the deploy began, and nothing from before' do
      deploy.set(logs: <<~LOGS)
        2000-01-01T00:00:00.000000+00:00 app[web.1]: ERROR from before the deploy
        2999-01-01T00:00:00.000000+00:00 app[web.1]: NoMethodError: undefined method
        2999-01-01T00:00:01.000000+00:00 app[web.1]: DEPRECATION WARNING: old call
        2999-01-01T00:00:02.000000+00:00 app[web.1]: Completed 200 OK
      LOGS

      result = deploy.run('--yes')

      expect(result.output).to include('Issues found in logs:', 'NoMethodError: undefined method',
                                       'DEPRECATION WARNING: old call')
      expect(result.output).not_to include('ERROR from before the deploy', 'Completed 200 OK', 'more (run:')
      # Issues in the log are a warning, not a failure: the health check,
      # the Solid Queue check and the smoke test still run. The text the
      # print loop reads ends with an empty line; until the loop used an
      # `if`, `[ -n "$line" ] && echo` made the loop's status 1 there, and
      # set -e with pipefail ended the deploy with no message.
      expect(result.output).to include('Health check', 'Deploy complete!')
      expect(result.status).to eq(0)
    end

    it 'shows warnings when there is no error' do
      deploy.set(logs: "2999-01-01T00:00:00.000000+00:00 app[web.1]: WARN slow query\n")

      result = deploy.run('--yes')

      expect(result.output).to include('Issues found in logs:', 'WARN slow query', 'Deploy complete!')
    end

    it 'shows 30 lines and counts the rest' do
      deploy.set(logs: (1..35).map { "2999-01-01T00:00:00.000000+00:00 app[web.1]: ERROR number #{it}\n" }.join)

      result = deploy.run('--yes')

      expect(result.output).to include('ERROR number 30', '...and 5 more (run: heroku logs -n 500 -a comeals-monorepo)')
      expect(result.output).not_to include('ERROR number 31')
    end

    it 'says so when the new lines hold no error or warning' do
      deploy.set(logs: "2999-01-01T00:00:00.000000+00:00 app[web.1]: Completed 200 OK\n")

      result = deploy.run('--yes')

      expect(result.output).to include('No errors, warnings, or deprecations found')
    end

    it 'says so when nothing was logged since the deploy' do
      deploy.set(logs: "2000-01-01T00:00:00.000000+00:00 app[web.1]: ERROR from before\n")

      result = deploy.run('--yes')

      expect(result.output).to include('No application log output since deploy')
    end
  end

  describe 'the health check' do
    it 'tries a URL again while it does not answer 200 or 302' do
      deploy.rule('curl', 'https://www.comeals.com$', stdout: '503', times: 2)
      deploy.rule('curl', 'https://admin.comeals.com$', stdout: '302')

      result = deploy.run('--yes')

      expect(result.output).to include('Got HTTP 503, retrying in 5s... (1/12)',
                                       'Got HTTP 503, retrying in 5s... (2/12)',
                                       'https://www.comeals.com returned HTTP 200',
                                       'https://admin.comeals.com returned HTTP 302')
      expect(deploy.calls_to('curl').grep(/www/).size).to eq(3)
      expect(result.status).to eq(0)
    end

    # State left: no maintenance, web at 1, new code live but one hostname
    # does not answer. Next step: check config.hosts, or roll back
    # (docs/runbooks/undo-a-deploy.md).
    it 'fails after 12 tries, counting a curl error as HTTP 000' do
      deploy.rule('curl', 'https://api.comeals.com$', exit: 7)

      result = deploy.run('--yes')

      expect(result.status).to eq(1)
      expect(result.output).to include('Got HTTP 000, retrying in 5s... (11/12)',
                                       'https://api.comeals.com returned HTTP 000 after 12 attempts')
      expect(result.output).not_to include('(12/12)', recovery_banner, 'Smoke test')
      expect(deploy.calls_to('curl').grep(/api\.comeals/).size).to eq(12)
      expect_production(maintenance: false, web: 1, pushed: true)
    end
  end

  describe 'the Solid Queue check' do
    it 'tries once more after 30 seconds' do
      deploy.rule('heroku', 'deploy:verify_solid_queue', exit: 1, times: 1)

      result = deploy.run('--yes')

      expect(result.output).to include('Not yet — retrying in 30s', 'Solid Queue is running')
      expect(deploy.calls).to include('sleep 30')
      expect(result.status).to eq(0)
    end

    # State left: no maintenance, web at 1, new code live without its
    # background jobs. Next step: the two checks the script prints.
    it 'fails after two tries' do
      deploy.rule('heroku', 'deploy:verify_solid_queue', exit: 1)

      result = deploy.run('--yes')

      expect(result.status).to eq(1)
      expect(result.output).to include(
        'Solid Queue is not running. Live updates and the nightly jobs are off until it is.',
        'Check: heroku logs -a comeals-monorepo | grep SolidQueue ; and docs/runbooks/scheduler-cutover.md'
      )
      expect(deploy.calls_to('heroku').grep(/verify_solid_queue/).size).to eq(2)
      expect(deploy.calls_to('smoke')).to eq([])
      expect_production(maintenance: false, web: 1, pushed: true)
    end
  end

  # State left: no maintenance, web at 1, new code live and broken. Next
  # step: roll back (docs/runbooks/undo-a-deploy.md).
  it 'fails and says to roll back when the smoke test fails' do
    deploy.rule('smoke', 'comeals\\.com', exit: 1, stdout: "login page did not load\n")

    result = deploy.run('--yes')

    expect(result.status).to eq(1)
    expect(result.output).to include('login page did not load',
                                     'SMOKE TEST FAILED — the deployed app is broken. Roll back.')
    expect(result.output).not_to include('Deploy complete!', recovery_banner)
    expect_production(maintenance: false, web: 1, pushed: true)
  end
end
