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
  let(:production_git) { 'https://git.heroku.com/comeals-monorepo.git' }
  # The heroku pg:psql call of bin/lib/wait_until_stopped.sh, not the one
  # that reads schema_migrations.
  let(:solid_queue_psql) { '^pg:psql .*solid_queue_processes' }

  after { deploy.cleanup }

  # This runs only when every example in the file ran, so one example on
  # its own (rspec spec/bin/deploy_spec.rb:42) can still pass. bin/check and
  # CI run the whole suite, so there it always runs.
  after(:context) do
    ran_all = self.class.descendant_filtered_examples.size == self.class.descendants.sum { it.examples.size }
    self.class.metadata[:bash_coverage].check! if ran_all
  end

  # Production as the run left it. `pushed` is true when the new code
  # reached Heroku. `worker` is the worker dyno count, nil when the
  # release has no worker process type.
  def expect_production(maintenance:, web:, pushed:, worker: 1)
    expect(deploy.state).to include(maintenance:, web:, worker:, pushed: pushed ? head : nil)
  end

  def expect_nothing_changed_in_production
    expect_production(maintenance: false, web: 1, pushed: false)
    expect(deploy.state[:backups]).to eq(0)
    expect(deploy.calls_to('heroku').grep(/maintenance|ps:scale|pg:backups:capture|run /)).to eq([])
  end

  # bin/deploy runs bin/smoke twice on production: once before it changes
  # anything, and once after. This answers the first call with a pass and
  # the second with `answer`.
  def smoke_after_the_deploy(**answer)
    deploy.rule('smoke', 'comeals\\.com', times: 1)
    deploy.rule('smoke', 'comeals\\.com', **answer)
  end

  # Before it changes anything, bin/deploy smokes production as it is. A
  # smoke login that the site refuses now would be refused after the
  # deploy too, and then nobody could tell whether the deploy broke it.
  # State left: nothing changed.
  describe 'the smoke test before the deploy' do
    it 'smokes production before the backup, and again after the deploy' do
      result = deploy.run('--yes')

      expect(result.status).to eq(0)
      expect(result.output).to include('Production passes the smoke test before the deploy')
      calls = deploy.calls
      smokes = calls.each_index.select { calls[it] == 'smoke https://comeals.com' }
      expect(smokes.size).to eq(2)
      expect(smokes.first).to be < calls.index('heroku pg:backups:capture -a comeals-monorepo')
      expect(smokes.last).to be > calls.index('git push heroku main --force')
    end

    it 'stops, and changes nothing, when production refuses a smoke login before the deploy' do
      deploy.rule('smoke', 'comeals\\.com', exit: 2, stdout: "SMOKE LOGIN REFUSED against https://comeals.com:\n")

      result = deploy.run('--yes')

      expect(result.status).to eq(1)
      expect(result.output).to include(
        'SMOKE LOGIN REFUSED against https://comeals.com:',
        'Production refused a smoke login before the deploy. Nothing was changed. Check the SMOKE_* credentials ' \
        '(in .env: SMOKE_* or RESIDENT_*/ADMIN_*), then deploy again.'
      )
      expect(deploy.calls_to('smoke')).to eq(['smoke https://comeals.com'])
      expect_nothing_changed_in_production
    end

    it 'stops, and changes nothing, when production fails the smoke test before the deploy' do
      deploy.rule('smoke', 'comeals\\.com', exit: 1, stdout: "login page did not load\n")

      result = deploy.run('--yes')

      expect(result.status).to eq(1)
      expect(result.output).to include(
        'login page did not load',
        'Production fails the smoke test before the deploy. Nothing was changed. ' \
        'Find out why first: bin/smoke https://comeals.com'
      )
      expect_nothing_changed_in_production
    end

    # SMOKE_BEFORE=skip lets a deploy go out when production fails the
    # smoke test now, for example a deploy that fixes that. Then nobody
    # knows whether the smoke logins worked before, so a refused login
    # after the deploy is not called a reason to roll back.
    context 'with SMOKE_BEFORE=skip' do
      let(:skipped) do
        'The smoke test before the deploy was skipped on purpose (SMOKE_BEFORE=skip). Nobody knows whether the ' \
          'smoke logins worked before the deploy, so a refused login after it will not say to roll back.'
      end

      it 'skips the smoke test before the deploy, says so, and still smokes after' do
        result = deploy.run('--yes', env: { 'SMOKE_BEFORE' => 'skip' })

        expect(result.status).to eq(0)
        expect(result.output).to include(skipped, 'Smoke test passed', 'Deploy complete!')
        expect(result.output).not_to include('Production passes the smoke test before the deploy')
        expect(deploy.calls_to('smoke')).to eq(['smoke https://comeals.com'])
      end

      it 'says to check the credentials, not to roll back, when a login is refused after the deploy' do
        deploy.rule('smoke', 'comeals\\.com', exit: 2)

        result = deploy.run('--yes', env: { 'SMOKE_BEFORE' => 'skip' })

        expect(result.status).to eq(1)
        expect(result.output).to include(
          skipped,
          'The site refused a smoke login. Every smoke check that could run passed, so do not roll back for this.'
        )
        expect(result.output).not_to include('Roll back.')
        expect_production(maintenance: false, web: 1, pushed: true)
      end
    end

    # A value that looks like skip but is not one must not deploy with the
    # check on while the person thinks it is off, or the other way round.
    ['Skip', 'skip ', 'yes', 'true', 'no'].each do |value|
      it "refuses SMOKE_BEFORE=#{value.inspect} before it runs anything" do
        result = deploy.run('--yes', env: { 'SMOKE_BEFORE' => value })

        expect(result.status).to eq(1)
        expect(result.output).to include("SMOKE_BEFORE is #{value.inspect}. It must be empty or skip. " \
                                         'Nothing was changed.')
        expect(deploy.calls).to eq([])
      end
    end
  end

  describe 'a push deploy (no migration changed)' do
    it 'pushes, checks the release, clears the cache, recalculates, checks the site, and says so' do
      result = deploy.run('--yes')

      expect(result.status).to eq(0)
      expect(result.output).to include('No new or changed migration — push deploy', 'PUSH deploy (no migrations)',
                                       'Proceeding without a prompt (--yes)', 'Release phase succeeded',
                                       'Cache flushed', 'Billing recalculated', 'Smoke test passed',
                                       'Deploy complete!')
      expect_production(maintenance: false, web: 1, pushed: true)
      expect(deploy.state[:backups]).to eq(1)
      expect(deploy.calls_to('heroku').grep(/maintenance|ps:scale/))
        .to eq(['heroku ps:scale worker=1 -a comeals-monorepo'])
      expect(deploy.calls).to include(
        'heroku run --exit-code bin/rails runner Rails.cache.clear -a comeals-monorepo',
        'heroku run --exit-code bin/rake billing:recalculate -a comeals-monorepo',
        'heroku run --exit-code bin/rake deploy:verify_solid_queue -a comeals-monorepo',
        'heroku run --exit-code bin/rake deploy:verify_recurring_job -a comeals-monorepo',
        'smoke https://comeals.com'
      )
      runs = deploy.calls_to('heroku').grep(/deploy:verify/)
      expect(runs.map { it[/deploy:\w+/] }).to eq(%w[deploy:verify_solid_queue deploy:verify_recurring_job])
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

    # The push restarts a worker dyno that runs. One that is at 0 stays at
    # 0: the first deploy whose release has a worker process type, or the
    # first after a rollback to a release without one.
    it 'starts the worker dyno when it is at 0, after the recalculation' do
      deploy.production(worker: 0)

      result = deploy.run('--yes')

      expect(result.status).to eq(0)
      expect_production(maintenance: false, web: 1, pushed: true, worker: 1)
      order = deploy.calls
      expect(order.index('heroku ps:scale worker=1 -a comeals-monorepo'))
        .to be > order.index('heroku run --exit-code bin/rake billing:recalculate -a comeals-monorepo')
    end

    it 'starts the worker dyno when the release before had no worker process type' do
      deploy.production(worker: 'none')

      result = deploy.run('--yes')

      expect(result.status).to eq(0)
      expect_production(maintenance: false, web: 1, pushed: true, worker: 1)
    end

    it 'takes the backup before it pushes' do
      deploy.run('--yes')

      order = deploy.calls.map { it.split.first(2).join(' ') }
      expect(order.index('heroku pg:backups:capture')).to be < order.index('git push')
    end
  end

  # After a deploy, the migrations production ran are deleted and
  # db/structure.sql is the record of the schema (AGENTS.md). A deleted
  # migration changes nothing in the database: its version stays in
  # schema_migrations, and the release phase's db:migrate has nothing to
  # run for it. So deleting one alone is a push deploy, and a new
  # migration in the same push is still found.
  describe 'a deploy that deletes migrations production has run' do
    # The new commit becomes HEAD and origin/main, so the deploy pushes it.
    def make_head(files)
      deploy.commits[:head] = deploy.commit(files, 'delete migrations')
      deploy.git('update-ref', 'refs/remotes/origin/main', head)
    end

    it 'is a push deploy when migrations were only deleted' do
      make_head('db/migrate/20260101000000_first.rb' => nil, 'db/migrate/20260201000000_second.rb' => nil)

      result = deploy.run('--yes')

      expect(result.status).to eq(0)
      expect(result.output).to include('No new or changed migration — push deploy', 'PUSH deploy (no migrations)')
      expect(result.output).not_to include('maintenance deploy required')
      expect(deploy.calls_to('heroku').grep(/maintenance/)).to eq([])
      expect_production(maintenance: false, web: 1, pushed: true)
    end

    # Deleting every migration leaves db/migrate/ empty, and git keeps an
    # empty folder only with a file in it. That file is not a migration:
    # db:migrate reads only <version>_<name>.rb. On 2026-10-26 production
    # showed the maintenance page for 4 minutes because of it.
    it 'is a push deploy when the only file added to db/migrate is not a migration' do
      make_head('db/migrate/20260101000000_first.rb' => nil, 'db/migrate/20260201000000_second.rb' => nil,
                'db/migrate/.keep' => '')

      result = deploy.run('--yes')

      expect(result.status).to eq(0)
      expect(result.output).to include('No new or changed migration — push deploy', 'PUSH deploy (no migrations)')
      expect(deploy.calls_to('heroku').grep(/maintenance/)).to eq([])
      expect_production(maintenance: false, web: 1, pushed: true)
    end

    # git calls a deleted file and an added one with nearly the same text
    # a rename. The added one is a new migration all the same.
    it 'is a maintenance deploy when the same push adds a migration with nearly the text of a deleted one' do
      body = "class Change < ActiveRecord::Migration[8.1]\n  def change\n    add_column :meals, :a, :text\n  end\nend\n"
      running = deploy.commit({ 'db/migrate/20260301000000_change.rb' => body }, 'production runs this')
      deploy.production(heroku_sha: running)
      make_head('db/migrate/20260301000000_change.rb' => nil,
                'db/migrate/20260401000000_change.rb' => body.sub(':a', ':b'))

      result = deploy.run('--yes')

      expect(result.status).to eq(0)
      expect(result.output).to include('Migration changes detected — maintenance deploy required:',
                                       'db/migrate/20260401000000_change.rb', 'MAINTENANCE deploy (has migrations)')
      expect(result.output).not_to include('db/migrate/20260301000000_change.rb')
      expect(deploy.calls).to include('heroku maintenance:on -a comeals-monorepo')
      expect_production(maintenance: false, web: 1, pushed: true)
    end
  end

  describe 'a maintenance deploy (a migration changed)' do
    before { deploy.production(heroku_sha: deploy.commits[:first_migration]) }

    # No job runs while the migrations run: the worker goes to 0 with web.
    # After the release, the worker starts before web and after the cache
    # clear and the recalculation, so its boot catch-up sees the fresh
    # balance run and does not run it a second time.
    it 'lists the migration, turns maintenance on, stops web and the worker, pushes, and brings everything back' do
      result = deploy.run('--yes')

      expect(result.status).to eq(0)
      expect(result.output).to include('Migration changes detected — maintenance deploy required:',
                                       'db/migrate/20260201000000_second.rb',
                                       'MAINTENANCE deploy (has migrations)', 'Deploy complete!')
      expect(result.output).not_to include(recovery_banner)
      expect_production(maintenance: false, web: 1, pushed: true, worker: 1)
      steps = deploy.calls_to('heroku')
                    .grep(/maintenance|ps:scale|ps -a|pg:psql|releases|SLUG_COMMIT|cache\.clear|billing|ledger/)
                    .map { it.sub(/^heroku pg:psql .*(pg_class|schema_migrations).*/, 'heroku pg:psql schema') }
                    .map { it.sub(/^heroku pg:psql .*solid_queue_processes.*/, 'heroku pg:psql') }
                    .map { it.delete_suffix(' --json').delete_suffix(' -a comeals-monorepo') }
      expect(steps).to eq([
                            'heroku config:get HEROKU_SLUG_COMMIT', 'heroku pg:psql schema', 'heroku pg:psql schema',
                            'heroku releases', 'heroku maintenance:on',
                            'heroku ps:scale', 'heroku ps:scale web=0 worker=0',
                            'heroku ps', 'heroku pg:psql',
                            'heroku releases', 'heroku releases:output', 'heroku config:get HEROKU_SLUG_COMMIT',
                            'heroku run --exit-code bin/rails runner Rails.cache.clear',
                            'heroku run --exit-code bin/rake billing:recalculate',
                            'heroku run --exit-code bin/rake ledger:verify',
                            'heroku ps:scale worker=1', 'heroku ps:scale web=1', 'heroku ps',
                            'heroku maintenance:off'
                          ])
      push = deploy.calls.index('git push heroku main --force')
      expect(push).to be > deploy.calls.index('heroku ps:scale web=0 worker=0 -a comeals-monorepo')
      expect(push).to be > deploy.calls.rindex { it.start_with?('heroku pg:psql') && it.include?('solid_queue') }
    end

    # #245. The release phase runs the migrations, and no process of the
    # old code may run beside them. heroku ps can list no worker while a
    # worker process that Heroku restarted still runs Solid Queue, so the
    # push also waits until no Solid Queue process sends heartbeats.
    it 'pushes only once no web or worker dyno runs and no Solid Queue process sends heartbeats' do
      deploy.rule('heroku', '^ps -a', times: 1, stdout: '[{"type":"worker","state":"up","release":{"version":700}}]')
      deploy.rule('heroku', solid_queue_psql, times: 1, stdout: " solid_queue \n-------------\n fresh=1\n(1 row)\n")

      result = deploy.run('--yes')

      expect(result.status).to eq(0)
      expect(result.output).to include('1 Solid Queue process(es) sent a heartbeat in the last 75 seconds',
                                       'No Solid Queue process sent a heartbeat in the last 75 seconds.')
      calls = deploy.calls
      psql = calls.each_index.select { calls[it].start_with?('heroku pg:psql') && calls[it].include?('solid_queue') }
      expect(psql.size).to eq(2)
      expect(calls.index('git push heroku main --force')).to be > psql.last
      expect(calls.each_index.select { calls[it] == 'heroku ps -a comeals-monorepo --json' }.first(2))
        .to all(be < psql.first)
    end

    # State left: maintenance on, web and the worker at 0, old code, no
    # migration run. Next step: what the script prints.
    it 'leaves maintenance on, pushes nothing, and says what to check when Solid Queue still runs after 3 minutes' do
      deploy.rule('heroku', solid_queue_psql, stdout: " solid_queue \n-------------\n fresh=1\n(1 row)\n")

      result = deploy.run('--yes')

      expect(result.status).to eq(1)
      expect(result.output).to include(
        '1 Solid Queue process(es) still sent a heartbeat in the last 75 seconds, 3 minutes after web and ' \
        'the worker were scaled to 0.',
        'Nothing was pushed, so no migration ran. Maintenance stays on.',
        'Find out what still runs: heroku ps -a comeals-monorepo ; ' \
        'heroku logs -a comeals-monorepo --dyno worker -n 200',
        'heroku pg:psql -a comeals-monorepo -c ' \
        '"SELECT kind, hostname, pid, last_heartbeat_at FROM solid_queue_processes"',
        'When nothing runs, run bin/deploy again. To give up the deploy instead, run the commands below.',
        recovery_banner
      )
      expect(deploy.calls_to('git').grep(/push/)).to eq([])
      expect_production(maintenance: true, web: 0, pushed: false, worker: 0)
    end

    # Production before its first deploy with a worker runs a release with
    # no worker process type, and Heroku refuses to scale one. The push
    # makes the type, so the worker can start after it.
    # That release runs no Solid Queue, and its database has no
    # solid_queue_processes table yet: the push's migrations make it.
    it 'stops only web when the running release has no worker process type, and starts the worker after' do
      deploy.production(worker: 'none')
      deploy.rule('heroku', solid_queue_psql, exit: 1,
                                              stderr: "ERROR:  relation \"solid_queue_processes\" does not exist\n")

      result = deploy.run('--yes')

      expect(result.status).to eq(0)
      expect(result.output).to include('The database has no solid_queue_processes table, so no Solid Queue ' \
                                       'process runs.')
      expect_production(maintenance: false, web: 1, pushed: true, worker: 1)
      expect(deploy.calls_to('heroku').grep(/ps:scale/)).to eq([
                                                                 'heroku ps:scale -a comeals-monorepo',
                                                                 'heroku ps:scale web=0 -a comeals-monorepo',
                                                                 'heroku ps:scale worker=1 -a comeals-monorepo',
                                                                 'heroku ps:scale web=1 -a comeals-monorepo'
                                                               ])
    end

    # #244. The deploy scales web to 0 for the migrations, and must bring
    # back as many web dynos as ran before, not always one.
    it 'brings web back to the count it had before, and waits for every one' do
      deploy.production(web: 2)

      result = deploy.run('--yes')

      expect(result.status).to eq(0)
      expect(result.output).to include('Scaling web back up to 2 dyno(s)...', 'Web is up on v701')
      expect(deploy.calls).to include('heroku ps:scale web=2 -a comeals-monorepo')
      expect_production(maintenance: false, web: 2, pushed: true)
    end

    # A deploy must leave the site serving, so web that was off comes
    # back as one dyno, and the script says so.
    it 'brings web up as one dyno when it was at 0 before, and says so' do
      deploy.production(web: 0)

      result = deploy.run('--yes')

      expect(result.status).to eq(0)
      expect(result.output).to include('Web ran 0 dynos before the deploy. It will come back as 1, so the site ' \
                                       'serves after the deploy.')
      expect_production(maintenance: false, web: 1, pushed: true)
    end

    it 'names the web count it read in the recovery banner' do
      deploy.production(web: 2)
      deploy.rule('heroku', '^ps:scale web=2', exit: 1)

      result = deploy.run('--yes')

      expect(result.status).to eq(1)
      expect(result.output).to include('heroku ps:scale web=2 -a comeals-monorepo')
      expect(result.output).not_to include('heroku ps:scale web=1 -a comeals-monorepo')
      expect_production(maintenance: true, web: 0, pushed: true, worker: 1)
    end

    # Heroku marks a web dyno "up" only once it listens on its port, and
    # Puma listens only after it has loaded the app. Until then a request
    # waits on a booting dyno, or fails when the boot fails. On 2026-10-23
    # maintenance went off 13 seconds before web.1 was up.
    it 'turns maintenance off only once web is up on the new release' do
      # The first answer is for the wait before the push.
      deploy.rule('heroku', '^ps -a', times: 1, stdout: '[]')
      deploy.rule('heroku', '^ps -a', times: 1,
                                      stdout: '[{"type":"web","state":"starting","release":{"version":701}}]')
      deploy.rule('heroku', '^ps -a', times: 1,
                                      stdout: '[{"type":"web","state":"up","release":{"version":700}}]')

      result = deploy.run('--yes')

      expect(result.status).to eq(0)
      expect(result.output).to include('Waiting for web to be up on v701...',
                                       'web on v701: starting — waiting (1/36)',
                                       'web on v701: no dyno yet — waiting (2/36)', 'Web is up on v701')
      expect_production(maintenance: false, web: 1, pushed: true)
      order = deploy.calls
      polls = order.each_index.select { order[it] == 'heroku ps -a comeals-monorepo --json' }
      expect(polls.size).to eq(4)
      expect(polls[1]).to be > order.index('heroku ps:scale web=1 -a comeals-monorepo')
      expect(polls.last).to be < order.index('heroku maintenance:off -a comeals-monorepo')
    end

    # State left: maintenance on, web at 1 but not up, worker at 1, new
    # code and migrations in. Next step: what the script prints.
    it 'leaves maintenance on and says what to do when web is not up after 3 minutes' do
      # The first answer is for the wait before the push.
      deploy.rule('heroku', '^ps -a', times: 1, stdout: '[]')
      deploy.rule('heroku', '^ps -a', stdout: '[{"type":"web","state":"crashed","release":{"version":701}}]')

      result = deploy.run('--yes')

      expect(result.status).to eq(1)
      expect(result.output).to include(
        'Web is not up on v701 after 3 minutes. Maintenance stays on.',
        'Find out why: heroku ps -a comeals-monorepo ; heroku logs -a comeals-monorepo --dyno web -n 200',
        'When heroku ps shows web up on v701, run: heroku maintenance:off -a comeals-monorepo',
        'Then check the site: bin/smoke https://comeals.com'
      )
      expect(deploy.calls_to('heroku').grep(/ps -a/).size).to eq(37)
      expect(deploy.calls_to('heroku').grep(/maintenance:off/)).to eq([])
      expect_production(maintenance: true, web: 1, pushed: true)
    end

    # After a rollback, the main branch of Heroku's git repository is the
    # commit that was rolled back, not the one that runs. A migration
    # between the two must still turn maintenance on.
    it 'compares migrations with the commit production runs, not with Heroku git main' do
      deploy.production(heroku_sha: deploy.commits[:first_migration], git_sha: deploy.commits[:second_migration])

      result = deploy.run('--yes')

      expect(result.output).to include('Migration changes detected — maintenance deploy required:',
                                       'db/migrate/20260201000000_second.rb', 'MAINTENANCE deploy (has migrations)')
      expect(deploy.calls).to include('heroku maintenance:on -a comeals-monorepo')
      expect_production(maintenance: false, web: 1, pushed: true)
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
                                       'Fetched Heroku main branch', 'No new or changed migration — push deploy')
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

  # #242. A rollback changes the release that runs, not Heroku's git
  # repository, so after one Heroku's git main can already be the commit
  # being deployed. A push then prints "Everything up-to-date", builds
  # nothing and makes no release.
  describe 'Heroku git already has this commit, but an older release runs (after a rollback)' do
    before { deploy.production(heroku_sha: deploy.commits[:second_migration], git_sha: head) }

    it 'refuses before anything in production changes, and says how to deploy the commit again' do
      result = deploy.run('--yes')

      expect(result.status).to eq(1)
      expect(result.output).to include(
        "Heroku's git already has #{head[0, 7]} on main, but comeals-monorepo runs " \
        "#{deploy.commits[:second_migration][0, 7]}. A push would build nothing.",
        'A rollback changes the release that runs, not what Heroku\'s git holds.',
        'To deploy this code again, see "Deploying a commit again after a rollback" in ' \
        'docs/runbooks/undo-a-deploy.md.'
      )
      expect(deploy.calls).to include('git ls-remote heroku refs/heads/main')
      expect(deploy.calls_to('bundle')).to eq([])
      expect(deploy.calls_to('git').grep(/push/)).to eq([])
      expect_nothing_changed_in_production
    end

    it 'asks the staging app, not the heroku remote, on staging' do
      deploy.production(config: { 'COMEALS_STAGING' => '1' })

      result = deploy.run('--yes', env: { 'DEPLOY_APP' => 'comeals-staging' })

      expect(result.status).to eq(1)
      expect(result.output).to include('A push would build nothing.')
      expect(deploy.calls).to include('git ls-remote https://git.heroku.com/comeals-staging.git refs/heads/main')
    end
  end

  it 'refuses when it cannot read the main branch of Heroku\'s git' do
    deploy.rule('git', '^ls-remote', exit: 128, stderr: "fatal: unable to access heroku\n")

    result = deploy.run('--yes')

    expect(result.status).to eq(1)
    expect(result.output).to include("Cannot read the main branch of Heroku's git (git ls-remote heroku)")
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

    # `heroku git:remote -a comeals-staging` points the heroku remote at
    # staging. The deploy would then back up and stop production, push the
    # new code to staging, and start production again on the old code.
    it 'refuses when the heroku remote points at another app' do
      deploy.git('remote', 'set-url', 'heroku', 'https://git.heroku.com/comeals-staging.git')

      result = deploy.run('--yes')

      expect(result.status).to eq(1)
      expect(result.output).to include(
        "The heroku remote points at https://git.heroku.com/comeals-staging.git, not at #{production_git}",
        'Run: heroku git:remote -a comeals-monorepo'
      )
      expect(deploy.calls_to('git').grep(/push|fetch heroku/)).to eq([])
      expect_nothing_changed_in_production
    end

    # The ssh address is the older form of the same remote.
    it 'accepts the ssh address of the production app' do
      deploy.git('remote', 'set-url', 'heroku', 'git@heroku.com:comeals-monorepo.git')

      result = deploy.run('--yes')

      expect(result.status).to eq(0)
      expect(result.output).to include('heroku remote -> git@heroku.com:comeals-monorepo.git')
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

    # #241. ESLint, Vitest and bin/smoke run with node_modules, which can
    # be older than package-lock.json (the pull above can make it so).
    it 'installs exactly the npm packages of package-lock.json, and the smoke browser, before the npm checks' do
      deploy.run('--yes')

      npm = deploy.calls.grep(/\Anp[mx] /)
      expect(npm).to eq(['npm ci', 'npx playwright install chromium', 'npm run lint', 'npm test'])
    end

    it 'stops when npm ci fails' do
      deploy.rule('npm', '^ci', exit: 1, stderr: "npm error code EUSAGE\n")

      result = deploy.run('--yes')

      expect(result.status).to eq(1)
      expect(result.output).to include('npm error code EUSAGE')
      expect(result.output).not_to include('node_modules matches package-lock.json')
      expect(deploy.calls_to('npx')).to eq([])
      expect_nothing_changed_in_production
    end

    it 'stops when the smoke browser cannot be installed' do
      deploy.rule('npx', '^playwright install', exit: 1, stderr: "Download failed\n")

      result = deploy.run('--yes')

      expect(result.status).to eq(1)
      expect(result.output).to include('Download failed')
      expect(deploy.calls_to('npm').grep(/lint|test/)).to eq([])
      expect_nothing_changed_in_production
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

  # After a deploy, the migrations production ran are deleted and
  # db/production_schema_version.txt names the newest of them. A database
  # restored from an older backup needs migrations that no longer exist,
  # and the release phase's db:migrate would run nothing (staging,
  # 2026-10-24). The release phase refuses such a database
  # (lib/squashed_migrations_check.rb); bin/deploy asks first, with the
  # same rule (bin/lib/schema-check), so it stops before the backup and
  # before maintenance goes on.
  describe 'the database schema version' do
    let(:schema_query) { /\Aheroku pg:psql -c .*pg_class.* -a comeals-monorepo\z/ }
    let(:behind_message) do
      'The database is behind db/production_schema_version.txt. Its newest migration is 20260101000000, ' \
        'but the file says 20260201000000: the migrations up to 20260201000000 were deleted from db/migrate/ ' \
        'after production ran them. db:migrate cannot run a migration that has no file, so this code would ' \
        'run on a database without the tables and columns those migrations made. Do one of these: restore a ' \
        'backup taken after production ran migration 20260201000000, or deploy a commit whose ' \
        'db/production_schema_version.txt is 20260101000000 or older (that commit still has the migration files).'
    end

    it 'reads it before the local checks, the backup and maintenance, and goes on when the database has it' do
      result = deploy.run('--yes')

      expect(result.status).to eq(0)
      expect(result.output).to include('The database has run every deleted migration; its newest is 20260201000000')
      order = deploy.calls
      read = order.index { it.match?(schema_query) }
      expect(read).to be < order.index('npm ci')
      expect(read).to be < order.index('heroku pg:backups:capture -a comeals-monorepo')
    end

    it 'goes on when the database is ahead of the file' do
      deploy.production(schema_version: '20260301000000')

      result = deploy.run('--yes')

      expect(result.status).to eq(0)
      expect(result.output).to include('The database has run every deleted migration; its newest is 20260301000000')
    end

    it 'refuses before anything in production changes when the database is behind, and says what to do' do
      deploy.production(schema_version: '20260101000000')

      result = deploy.run('--yes')

      expect(result.status).to eq(1)
      expect(result.output).to include(behind_message, 'Nothing was changed.')
      expect(deploy.calls_to('npm')).to eq([])
      expect(deploy.calls_to('git').grep(/\Agit push/)).to eq([])
      expect_nothing_changed_in_production
    end

    it 'refuses a maintenance deploy the same way, before maintenance goes on' do
      deploy.production(heroku_sha: deploy.commits[:first_migration], schema_version: '20260101000000')

      result = deploy.run('--yes')

      expect(result.status).to eq(1)
      expect(result.output).to include(behind_message)
      expect(result.output).not_to include(recovery_banner)
      expect_nothing_changed_in_production
    end

    # #248: the release phase compares every migration db/structure.sql
    # lists up to the file's version, not only the newest. bin/deploy uses
    # the same rule (bin/lib/schema-check), so it stops before the backup
    # and maintenance instead of in the release phase.
    it 'refuses before anything in production changes when the database is missing an older migration' do
      deploy.production(schema_versions: ['20260201000000'])

      result = deploy.run('--yes')

      expect(result.status).to eq(1)
      expect(result.output).to include('The database has not run 1 of the migrations that were deleted from ' \
                                       'db/migrate/ after production ran them: 20260101000000.', 'Nothing was changed.')
      expect(deploy.calls_to('npm')).to eq([])
      expect_nothing_changed_in_production
    end

    # db:migrate would load db/structure.sql over the tables, or do
    # nothing; the release phase refuses it, so bin/deploy does too.
    it 'refuses before anything in production changes when the database has tables but no versions' do
      deploy.production(schema_versions: [])

      result = deploy.run('--yes')

      expect(result.status).to eq(1)
      expect(result.output).to include('The database has tables (meals, schema_migrations) but no record of the ' \
                                       'migrations it has run', 'Nothing was changed.')
      expect_nothing_changed_in_production
    end

    # A brand new app, before its schema is loaded from db/structure.sql.
    # The release phase lets it through too, and builds it.
    it 'goes on when the database has no tables, and does not ask for the versions' do
      deploy.production(tables: [], schema_versions: [])

      result = deploy.run('--yes')

      expect(result.status).to eq(0)
      expect(result.output).to include('The database has no tables, so it is new: the release phase builds it ' \
                                       'from db/structure.sql')
      expect(deploy.calls.grep(/version=/)).to eq([])
    end

    # No schema_migrations table: db:migrate would load db/structure.sql
    # over the tables.
    it 'refuses a database with tables but no schema_migrations table' do
      deploy.production(tables: %w[meals], schema_versions: [])

      result = deploy.run('--yes')

      expect(result.status).to eq(1)
      expect(result.output).to include('The database has tables (meals) but no record', 'Nothing was changed.')
      expect(deploy.calls.grep(/version=/)).to eq([])
      expect_nothing_changed_in_production
    end

    it 'refuses, and names the error, when it cannot read the tables' do
      deploy.rule('heroku', '^pg:psql .*pg_class', exit: 1, stderr: "\n !    Couldn't find that app.\n\n")

      result = deploy.run('--yes')

      expect(result.status).to eq(1)
      expect(result.output).to include(
        "Could not read the tables in the database of comeals-monorepo ( !    Couldn't find that app.). " \
        'Nothing was changed.'
      )
      expect_nothing_changed_in_production
    end

    it 'refuses, and names the error, when it cannot read the migrations' do
      deploy.rule('heroku', "^pg:psql .*'version='", exit: 1, stderr: "ERROR:  canceling statement\n")

      result = deploy.run('--yes')

      expect(result.status).to eq(1)
      expect(result.output).to include('Could not read the migrations in the database of comeals-monorepo (ERROR:  ' \
                                       'canceling statement). Nothing was changed.')
      expect_nothing_changed_in_production
    end

    # A read that stopped part way must not look like a database with no
    # tables, which goes on.
    it 'refuses when the read succeeds but has no end=ok line' do
      deploy.rule('heroku', '^pg:psql .*pg_class', stdout: " line \n------\n table=meals\n")

      result = deploy.run('--yes')

      expect(result.status).to eq(1)
      expect(result.output).to include('in the database of comeals-monorepo ( table=meals). Nothing was changed.')
      expect_nothing_changed_in_production
    end

    it 'says "no output" when the failed read printed nothing' do
      deploy.rule('heroku', '^pg:psql .*pg_class', exit: 1)

      result = deploy.run('--yes')

      expect(result.status).to eq(1)
      expect(result.output).to include('in the database of comeals-monorepo (no output)')
    end

    it 'refuses, and says why, when db/structure.sql cannot be read' do
      deploy.commits[:head] = deploy.commit({ 'db/structure.sql' => "CREATE TABLE meals ();\n" }, 'no list')
      deploy.git('update-ref', 'refs/remotes/origin/main', head)

      result = deploy.run('--yes')

      expect(result.status).to eq(1)
      expect(result.output).to include('Could not check the database of comeals-monorepo against db/structure.sql ' \
                                       '(db/structure.sql has no INSERT INTO schema_migrations list). Nothing was ' \
                                       'changed.')
      expect_nothing_changed_in_production
    end

    it 'refuses when db/production_schema_version.txt does not hold one version' do
      deploy.commits[:head] = deploy.commit({ 'db/production_schema_version.txt' => "# only a comment\n" }, 'empty')
      deploy.git('update-ref', 'refs/remotes/origin/main', head)

      result = deploy.run('--yes')

      expect(result.status).to eq(1)
      expect(result.output).to include('db/production_schema_version.txt must hold one version of 14 digits. ' \
                                       'Nothing was changed.')
      expect(deploy.calls.grep(schema_query)).to eq([])
      expect_nothing_changed_in_production
    end

    it 'asks the staging database on staging' do
      deploy.production(config: { 'COMEALS_STAGING' => '1' })

      result = deploy.run('--yes', env: { 'DEPLOY_APP' => 'comeals-staging' })

      expect(result.status).to eq(0)
      expect(deploy.calls.grep(/pg_class|schema_migrations/)).to eq(
        ["heroku pg:psql -c SELECT 'table=' || c.relname AS line FROM pg_class c JOIN pg_namespace n ON n.oid = " \
         "c.relnamespace WHERE c.relkind IN ('r', 'p') AND n.nspname = ANY (current_schemas(false)) UNION ALL " \
         "SELECT 'end=ok' -a comeals-staging",
         "heroku pg:psql -c SELECT 'version=' || version AS line FROM schema_migrations UNION ALL SELECT 'end=ok' " \
         '-a comeals-staging']
      )
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

  # The jobs dyno sets its own pool in the Procfile, and web, one-off
  # dynos and the release phase keep database.yml's default. So the
  # deploy reads and writes no config var.
  it 'reads and sets no config var, even with no RAILS_DB_POOL' do
    deploy.production(config: {})

    result = deploy.run('--yes')

    expect(result.status).to eq(0)
    expect(result.output).not_to include('RAILS_DB_POOL', 'database pool')
    expect(deploy.calls_to('heroku').grep(/config:set|config:get RAILS_DB_POOL/)).to eq([])
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
      expect(result.output).to include('The release phase did not succeed (status: failed). Its output is above.',
                                       'Running release command... migrating')
      expect(result.output).not_to include('Maintenance stays on', recovery_banner, 'Cache flushed')
      expect(deploy.calls).to include('heroku releases:output -a comeals-monorepo')
      expect_production(maintenance: false, web: 1, pushed: true)
    end

    it 'waits while the release is pending' do
      deploy.production(releases: %w[pending pending succeeded])

      result = deploy.run('--yes')

      expect(result.output).to include('Release phase succeeded', 'Deploy complete!')
      # One read before the push, then three after it.
      expect(deploy.calls_to('heroku').grep(/releases -a/).size).to eq(4)
      expect(deploy.calls_to('sleep').first(2)).to eq(['sleep 5', 'sleep 5'])
    end

    # State left: no maintenance, web at 1, the release may still finish
    # later. Next step: heroku releases -a comeals-monorepo, and read the
    # release output once it is done.
    it 'gives up after 36 checks of a release that stays pending' do
      deploy.production(releases: ['pending'] * 40)

      result = deploy.run('--yes')

      expect(result.status).to eq(1)
      expect(result.output).to include('The release phase did not succeed (status: pending). Its output is above.')
      expect(deploy.calls_to('heroku').grep(/releases -a/).size).to eq(1 + 36)
      expect(deploy.calls_to('sleep')).to eq(['sleep 5'] * 36)
    end

    # The script stops with Python's error and no line of its own. The code
    # is pushed; the release may have worked. Next step: heroku releases.
    it 'stops with no message of its own when Heroku cannot list the releases after the push' do
      deploy.rule('heroku', '^releases -a', times: 1, stdout: %([{"version":700,"status":"succeeded"}]\n))
      deploy.rule('heroku', '^releases -a', exit: 1, stderr: "releases failed\n")

      result = deploy.run('--yes')

      expect(result.status).to eq(1)
      expect(result.output).to include('releases failed', 'JSONDecodeError')
      expect(result.output).not_to include('release phase did not succeed', recovery_banner)
      expect_production(maintenance: false, web: 1, pushed: true)
    end

    # Another push of the same commit got there first, or Heroku's git
    # changed after the check before the push. State left: no
    # maintenance, web at 1, old code. Next step: heroku releases.
    it 'stops before the cache clear when the push made no new release' do
      deploy.rule('git', '^push heroku', stderr: "Everything up-to-date\n", stdout: '')

      result = deploy.run('--yes')

      expect(result.status).to eq(1)
      expect(result.output).to include('The push made no new release: the newest release of comeals-monorepo ' \
                                       'is still v700.')
      expect(result.output).not_to include('Release phase succeeded', 'Cache flushed', 'Maintenance stays on')
      expect(deploy.calls_to('heroku').grep(/run |ps:scale/)).to eq([])
      expect_production(maintenance: false, web: 1, pushed: false)
    end

    # A rollback or another deploy ran at the same moment. State left: no
    # maintenance, web at 1, some other commit. Next step: heroku releases.
    it 'stops when the new release succeeded but another commit runs' do
      running = deploy.commits[:second_migration]
      deploy.rule('heroku', '^config:get HEROKU_SLUG_COMMIT', times: 1, stdout: "#{running}\n")
      deploy.rule('heroku', '^config:get HEROKU_SLUG_COMMIT', stdout: "#{'b' * 40}\n")

      result = deploy.run('--yes')

      expect(result.status).to eq(1)
      expect(result.output).to include("Release v701 succeeded, but comeals-monorepo runs bbbbbbb, not #{head[0, 7]}.")
      expect(result.output).not_to include('Cache flushed')
    end

    it 'stops before the backup when Heroku cannot list the releases before the push' do
      deploy.rule('heroku', '^releases -a', exit: 1, stderr: "releases failed\n")

      result = deploy.run('--yes')

      expect(result.status).to eq(1)
      expect(result.output).to include('releases failed')
      expect_nothing_changed_in_production
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
                                       'The web and worker dynos may be scaled to 0.',
                                       'heroku ps:scale worker=1 -a comeals-monorepo',
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

    # State left: maintenance on, web and worker at 1, old code. Next step:
    # the commands the banner prints.
    it 'stops with the recovery banner when the formation cannot be read' do
      deploy.rule('heroku', '^ps:scale -a', exit: 1)

      result = deploy.run('--yes')

      expect(result.status).to eq(1)
      expect_recovery_banner(result)
      expect_production(maintenance: true, web: 1, pushed: false, worker: 1)
    end

    # State left: maintenance on, web at 1, old code. Next step: the
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
      expect_production(maintenance: true, web: 0, pushed: false, worker: 0)
    end

    # State left: maintenance on, web at 0, new code pushed, migrations
    # maybe half run. Next step: read the release output, do not scale up
    # (docs/runbooks/undo-a-deploy.md).
    it 'keeps maintenance on and web at 0 when the release phase fails, and says why' do
      deploy.production(releases: %w[failed])

      result = deploy.run('--yes')

      expect(result.status).to eq(1)
      expect(result.output).to include(
        'The release phase did not succeed (status: failed). Its output is above.',
        'Maintenance stays on and web and the worker stay at 0. Do not scale them up until you know which ' \
        'migrations ran: the old code may not work on the new schema.'
      )
      expect_recovery_banner(result)
      expect(deploy.calls_to('heroku').grep(/run --exit-code/)).to eq([])
      expect_production(maintenance: true, web: 0, pushed: true, worker: 0)
    end

    # State left: maintenance on, web and worker at 0, old code, no
    # migration ran. Next step: the commands the banner prints.
    it 'says the old code still runs when the push made no new release' do
      deploy.rule('git', '^push heroku', stderr: "Everything up-to-date\n", stdout: '')

      result = deploy.run('--yes')

      expect(result.status).to eq(1)
      expect(result.output).to include('The push made no new release',
                                       'Nothing was deployed and no migration ran. It is safe to bring the old ' \
                                       'code back up with the commands below.')
      expect_recovery_banner(result)
      expect_production(maintenance: true, web: 0, pushed: false, worker: 0)
    end

    # State left: maintenance on, web and worker at 0, new code and
    # migrations in. Next step: the commands the banner prints.
    it 'stops with the recovery banner when the worker cannot be scaled back up' do
      deploy.rule('heroku', '^ps:scale worker=1', exit: 1)

      result = deploy.run('--yes')

      expect(result.status).to eq(1)
      expect_recovery_banner(result)
      expect_production(maintenance: true, web: 0, pushed: true, worker: 0)
    end

    # State left: maintenance on, web at 0, worker at 1, new code and
    # migrations in. Next step: the commands the banner prints.
    it 'stops with the recovery banner when web cannot be scaled back up' do
      deploy.rule('heroku', '^ps:scale web=1', exit: 1)

      result = deploy.run('--yes')

      expect(result.status).to eq(1)
      expect_recovery_banner(result)
      expect_production(maintenance: true, web: 0, pushed: true, worker: 1)
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
      expect(result.output).not_to include('(12/12)', recovery_banner, 'Browser smoke test')
      expect(deploy.calls_to('smoke')).to eq(['smoke https://comeals.com'])
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
        'Check: heroku ps -a comeals-monorepo ; heroku logs -a comeals-monorepo --dyno worker | grep SolidQueue ; ' \
        'and docs/runbooks/scheduler-cutover.md'
      )
      expect(deploy.calls_to('heroku').grep(/verify_solid_queue/).size).to eq(2)
      expect(deploy.calls_to('smoke')).to eq(['smoke https://comeals.com'])
      expect_production(maintenance: false, web: 1, pushed: true)
    end
  end

  # Every process can have a heartbeat while its work fails: on staging
  # on 2026-10-20 the scheduler queued nothing at any tick. The check
  # waits for the worker itself (up to two minutes), so it runs once.
  # State left: no maintenance, web at 1, new code live, its jobs not
  # working. Next step: the log the script names, then roll back.
  describe 'the recurring job check' do
    it 'fails when the worker did not run a queued recurring task' do
      deploy.rule('heroku', 'deploy:verify_recurring_job', exit: 1)

      result = deploy.run('--yes')

      expect(result.status).to eq(1)
      expect(result.output).to include(
        'Solid Queue is up, but a recurring task did not run. The nightly jobs and live updates may not run.',
        'Read the error above, then: heroku logs -a comeals-monorepo --dyno worker | grep -i error'
      )
      expect(deploy.calls_to('heroku').grep(/verify_recurring_job/).size).to eq(1)
      expect(deploy.calls_to('smoke')).to eq(['smoke https://comeals.com'])
      expect_production(maintenance: false, web: 1, pushed: true)
    end
  end

  # State left: no maintenance, web at 1, new code live and broken. Next
  # step: roll back (docs/runbooks/undo-a-deploy.md).
  it 'fails and says to roll back when the smoke test fails' do
    smoke_after_the_deploy(exit: 1, stdout: "login page did not load\n")

    result = deploy.run('--yes')

    expect(result.status).to eq(1)
    expect(result.output).to include('login page did not load',
                                     'SMOKE TEST FAILED — the deployed app is broken. Roll back.')
    expect(result.output).not_to include('Deploy complete!', recovery_banner)
    expect_production(maintenance: false, web: 1, pushed: true)
  end

  # bin/smoke ends with 2 when the site answered and refused a smoke
  # login. The same login worked before the deploy, so the deploy broke
  # it. State left: no maintenance, web at 1, new code live.
  it 'says to roll back when the deploy broke a smoke login that worked before it' do
    smoke_after_the_deploy(exit: 2, stdout: "SMOKE LOGIN REFUSED against https://comeals.com:\n")

    result = deploy.run('--yes')

    expect(result.status).to eq(1)
    expect(result.output).to include(
      'SMOKE LOGIN REFUSED against https://comeals.com:',
      'SMOKE TEST FAILED — the site refused a smoke login that worked before this deploy, so the deploy broke it. ' \
      'Roll back.'
    )
    expect(result.output).not_to include('Deploy complete!', recovery_banner)
    expect_production(maintenance: false, web: 1, pushed: true)
  end

  # Any code but 0 and 2 is a broken site, or a smoke test that could
  # not run; either way the deploy is not known to work.
  it 'says to roll back when the smoke test ends with any other code' do
    smoke_after_the_deploy(exit: 127)

    result = deploy.run('--yes')

    expect(result.status).to eq(1)
    expect(result.output).to include('SMOKE TEST FAILED — the deployed app is broken. Roll back.')
  end

  # Everything the run prints, the build output Heroku sends back through
  # git push and the release phase output included, also goes to one file
  # per run. The person running the deploy keeps it.
  describe 'the deploy log' do
    it 'saves everything it prints to tmp/deploy/deploy-<time>-<app>.log, and still prints it' do
      deploy.set(push_output: "remote: Building source\nremote: Compiling assets\n")

      result = deploy.run('--yes')

      expect(deploy.deploy_logs.size).to eq(1)
      log = deploy.deploy_logs.first
      expect(File.basename(log)).to match(/\Adeploy-\d{8}T\d{6}Z-comeals-monorepo\.log\z/)
      expect(File.read(log).gsub(/\e\[[0-9;]*m/, '')).to eq(result.output)
      expect(result.output).to include('Comeals Deploy', 'remote: Building source', 'remote: Compiling assets',
                                       'Release phase output:', 'Running release command... migrating',
                                       'Deploy complete!',
                                       "The whole output of this run is in #{log.delete_prefix("#{deploy.repo}/")}")
    end

    it 'saves the log of a run that fails' do
      deploy.rule('heroku', '^pg:backups:capture', exit: 1, stderr: "backup failed\n")

      result = deploy.run('--yes')

      expect(result.status).to eq(1)
      expect(File.read(deploy.deploy_logs.first)).to include('backup failed', 'Warnings seen during this deploy')
    end

    it 'names the staging app in the file name on staging' do
      deploy.production(config: { 'COMEALS_STAGING' => '1' })

      deploy.run('--yes', env: { 'DEPLOY_APP' => 'comeals-staging' })

      expect(File.basename(deploy.deploy_logs.first)).to match(/\Adeploy-\d{8}T\d{6}Z-comeals-staging\.log\z/)
    end
  end

  # At the end of every run, worked or not, the warnings in the run's
  # output and in the app log lines the log check read, each one once,
  # against docs/deploy-known-warnings.txt. Warnings never change the exit
  # status: the deploy is already done.
  describe 'the warnings section' do
    let(:buildpack_warning) do
      "remote: ###### WARNING:\nremote:\nremote:        Your app's bin/bundle is not the one Bundler made\n"
    end

    it 'lists new and known warnings from the output and the app log, and still succeeds' do
      deploy.set(push_output: buildpack_warning)
      deploy.rule('heroku', '^pg:backups:capture', stdout: "Backing up DATABASE to b001... done\n",
                                                   stderr: ' ›   Warning: Logical backups of large databases ' \
                                                           "are likely to fail.\n")
      deploy.set(logs: "2999-01-01T00:00:00.000000+00:00 app[web.1]: W, [x #2]  WARN -- slow query\n" * 2)

      result = deploy.run('--yes')

      expect(result.status).to eq(0)
      section = result.output[/Warnings seen during this deploy.*\z/m]
      expect(section).to include("NEW: ###### WARNING: Your app's bin/bundle is not the one Bundler made",
                                 'NEW: WARN -- slow query (seen 2 times)', 'known (Heroku says this',
                                 '2 new, 1 known')
      expect(result.output.index('Warnings seen')).to be > result.output.index('Deploy complete!')
    end

    it 'runs after a failure, and the exit status stays the failure' do
      deploy.rule('git', '^push heroku', stdout: buildpack_warning, exit: 1)

      result = deploy.run('--yes')

      expect(result.status).to eq(1)
      expect(result.output).to include('Warnings seen during this deploy', 'NEW: ###### WARNING:')
    end

    it 'says so when there is none' do
      result = deploy.run('--yes')

      expect(result.output).to include('Warnings seen during this deploy', 'No warning lines.')
    end

    it 'runs when there is nothing to deploy' do
      deploy.production(heroku_sha: head)

      result = deploy.run('--yes')

      expect(result.status).to eq(0)
      expect(result.output).to include('Already up to date', 'No warning lines.')
    end

    it 'says so, and keeps the exit status, when the search fails' do
      deploy.break_tool('python3')
      deploy.production(heroku_sha: head)

      result = deploy.run('--yes')

      expect(result.status).to eq(0)
      expect(result.output).to include('Could not search this run\'s output for warnings')
    end
  end

  # After the balance refresh, check every settled balance against its
  # source data (rake ledger:verify), the same way the other tasks run.
  describe 'the ledger check' do
    it 'runs after the recalculation and before the worker starts' do
      result = deploy.run('--yes')

      expect(result.output).to include('Ledger check passed')
      calls = deploy.calls
      ledger = calls.index('heroku run --exit-code bin/rake ledger:verify -a comeals-monorepo')
      expect(ledger).to be > calls.index('heroku run --exit-code bin/rake billing:recalculate -a comeals-monorepo')
      expect(ledger).to be < calls.index('heroku ps:scale worker=1 -a comeals-monorepo')
    end

    # State left: no maintenance, web at 1, the new code serving. Next
    # step: the Rollback workflow. No migration ran, so the code alone can
    # go back; the backup is there if the data must go back too.
    it 'stops a push deploy, says the site serves the new code, and prints the rollback' do
      deploy.rule('heroku', '^run --exit-code bin/rake ledger:verify', exit: 1, stderr: "3 balances differ\n")

      result = deploy.run('--yes')

      expect(result.status).to eq(1)
      expect(result.output).to include(
        '3 balances differ', 'THE LEDGER CHECK FAILED after the deploy',
        'Maintenance is off: comeals-monorepo serves the new code now.',
        'gh workflow run rollback.yml --ref main -f app=comeals-monorepo -f release=v700 ' \
        "-f reason=\"The ledger check failed after the deploy of #{head[0, 7]}\"",
        'add: -f backup=b001'
      )
      expect(result.output).not_to include('Smoke test passed', 'Deploy complete!', recovery_banner)
      expect(deploy.calls_to('smoke')).to eq(['smoke https://comeals.com'])
      expect_production(maintenance: false, web: 1, pushed: true)
    end

    # State left: maintenance on, web and the worker at 0, the migrations
    # run. Next step: the Rollback workflow with the backup. The banner
    # that says to scale up does not show: the balances may be wrong.
    it 'stops a maintenance deploy with maintenance on and everything at 0, and prints the rollback with the backup' do
      deploy.production(heroku_sha: deploy.commits[:first_migration])
      deploy.rule('heroku', '^run --exit-code bin/rake ledger:verify', exit: 1)

      result = deploy.run('--yes')

      expect(result.status).to eq(1)
      expect(result.output).to include(
        'THE LEDGER CHECK FAILED after the deploy',
        'Maintenance is on, and web and the worker are at 0',
        'gh workflow run rollback.yml --ref main -f app=comeals-monorepo -f release=v700 -f backup=b001 ' \
        "-f reason=\"The ledger check failed after the deploy of #{head[0, 7]}\""
      )
      expect(result.output).not_to include(recovery_banner, 'Deploy complete!')
      expect_production(maintenance: true, web: 0, pushed: true, worker: 0)
    end

    it 'says how to find the backup id when it could not read it' do
      deploy.production(heroku_sha: deploy.commits[:first_migration])
      deploy.rule('heroku', '^pg:backups:info', exit: 1, stdout: "info failed\n")
      deploy.rule('heroku', '^run --exit-code bin/rake ledger:verify', exit: 1)

      result = deploy.run('--yes')

      expect(result.output).to include('-f backup="<the newest backup in: heroku pg:backups -a comeals-monorepo>"')
    end
  end

  # bin/smoke signs in only with credentials. On production, bin/deploy
  # takes them from .env when the environment does not have them: only
  # those four variables, never the whole file.
  describe 'the smoke credentials' do
    let(:owner_env) do
      <<~ENV
        PUSHER_SECRET=px-canary
        RESIDENT_USER=user-name
        RESIDENT_PASSWORD='resident-pass-1'
        ADMIN_USER=admin-name
        ADMIN_PASSWORD='admin-pass-1'
        RESIDENT_EMAIL='resident@example.com'
        RESIDENT_PASSWORD='resident-pass-1'
        ADMIN_EMAIL="admin@example.com"
        ADMIN_PASSWORD='admin-pass-1'
      ENV
    end
    let(:from_owner_env) do
      { 'SMOKE_EMAIL' => 'resident@example.com', 'SMOKE_PASSWORD' => 'resident-pass-1',
        'SMOKE_ADMIN_EMAIL' => 'admin@example.com', 'SMOKE_ADMIN_PASSWORD' => 'admin-pass-1',
        'RESIDENT_PASSWORD' => '<unset>' }
    end

    it 'reads them from the RESIDENT_* and ADMIN_* lines of .env, without quotes, and passes nothing else' do
      deploy.env_file(owner_env)

      result = deploy.run('--yes')

      expect(result.status).to eq(0)
      expect(deploy.smoke_env).to eq(from_owner_env)
      expect(result.output).not_to include('logged-in smoke checks')
      expect(File.read(deploy.deploy_logs.first)).not_to include('resident-pass-1', 'admin-pass-1', 'px-canary')
    end

    it 'prefers SMOKE_* lines in .env, and the environment over .env' do
      deploy.env_file("#{owner_env}SMOKE_EMAIL=smoke@example.com\nexport SMOKE_PASSWORD=\"smoke-pass\"\n")

      deploy.run('--yes', env: { 'SMOKE_ADMIN_PASSWORD' => 'from-the-environment' })

      expect(deploy.smoke_env).to include('SMOKE_EMAIL' => 'smoke@example.com', 'SMOKE_PASSWORD' => 'smoke-pass',
                                          'SMOKE_ADMIN_EMAIL' => 'admin@example.com',
                                          'SMOKE_ADMIN_PASSWORD' => 'from-the-environment')
    end

    it 'says which variables are missing when the logged-in checks will be skipped' do
      deploy.env_file("RESIDENT_EMAIL=resident@example.com\n")

      result = deploy.run('--yes')

      expect(result.status).to eq(0)
      expect(result.output).to include('Some logged-in smoke checks will be skipped. Not set, and not in .env: ' \
                                       'SMOKE_PASSWORD SMOKE_ADMIN_EMAIL SMOKE_ADMIN_PASSWORD')
      expect(deploy.smoke_env).to include('SMOKE_EMAIL' => 'resident@example.com', 'SMOKE_PASSWORD' => '<unset>')
    end

    it 'says all four are missing when there is no .env' do
      result = deploy.run('--yes')

      expect(result.output).to include('Not set, and not in .env: SMOKE_EMAIL SMOKE_PASSWORD SMOKE_ADMIN_EMAIL ' \
                                       'SMOKE_ADMIN_PASSWORD')
    end

    # Staging signs in with its own smoke resident (bin/staging-rehearsal),
    # never with the owner's accounts.
    it 'does not read .env on staging' do
      deploy.production(config: { 'COMEALS_STAGING' => '1' })
      deploy.env_file(owner_env)

      result = deploy.run('--yes', env: { 'DEPLOY_APP' => 'comeals-staging' })

      expect(result.status).to eq(0)
      expect(deploy.smoke_env.values).to all(eq('<unset>'))
      expect(result.output).not_to include('logged-in smoke checks')
    end
  end

  # DEPLOY_APP=comeals-staging runs the same deploy on the staging app, so
  # a deploy can be tried there first, the whole way through. The fake
  # heroku keeps one app's state whatever -a names, so these examples
  # check the app in every call instead.
  describe 'DEPLOY_APP' do
    let(:staging) { { 'DEPLOY_APP' => 'comeals-staging' } }
    let(:staging_url) { 'https://comeals-staging-ad51b8a1eb64.herokuapp.com' }
    let(:staging_git) { 'https://git.heroku.com/comeals-staging.git' }

    # Staging holds a copy of the production database. COMEALS_STAGING
    # turns its mail and Pusher off.
    before { deploy.production(config: { 'COMEALS_STAGING' => '1' }) }

    # No call to any fake names the production app, and no git command
    # uses the heroku remote, which points at production.
    def expect_production_untouched(result)
      expect(deploy.calls.grep(/comeals-monorepo/)).to eq([])
      expect(result.output).not_to include('comeals-monorepo', 'https://comeals.com')
      expect(deploy.calls_to('git').grep(/\Agit \S+ heroku\b/)).to eq([])
      expect(deploy.calls_to('heroku').grep(/ -a /)).to all(match(/ -a comeals-staging( |\z)/))
    end

    it 'deploys to production when it is not set' do
      result = deploy.run('--yes')

      expect(result.output).to include('Target: comeals-monorepo (https://comeals.com)')
      expect(deploy.calls).to include('git push heroku main --force')
    end

    ['comeals-prod', 'comeals-staging ', ''].each do |app|
      it "refuses #{app.inspect} before it runs anything" do
        result = deploy.run('--yes', env: { 'DEPLOY_APP' => app })

        expect(result.status).to eq(1)
        expect(result.output).to include("DEPLOY_APP is #{app.inspect}. It must be comeals-monorepo or " \
                                         'comeals-staging. Nothing was changed.')
        expect(deploy.calls).to eq([])
      end
    end

    # Staging is parked at 0 dynos between rehearsals, so there is no site
    # to smoke before the deploy, and so no login known to have worked. A
    # refused login after the deploy then means the credentials are wrong.
    it 'does not smoke staging before the deploy, and says to check the credentials when a login is refused' do
      deploy.rule('smoke', 'herokuapp\\.com', exit: 2)

      result = deploy.run('--yes', env: staging.merge('SMOKE_EMAIL' => 'smoke@example.com',
                                                      'SMOKE_PASSWORD' => 'smoke-pass'))

      expect(result.status).to eq(1)
      expect(deploy.calls_to('smoke')).to eq(["smoke #{staging_url}"])
      expect(result.output).to include(
        'The site refused a smoke login. Every smoke check that could run passed, so do not roll back for this. ' \
        "Check the SMOKE_* credentials (in .env: SMOKE_* or RESIDENT_*/ADMIN_*), then run: bin/smoke #{staging_url}"
      )
      expect(result.output).not_to include('Roll back.')
    end

    it 'runs a push deploy on staging, end to end, and never names production' do
      result = deploy.run('--yes', env: staging)

      expect(result.status).to eq(0)
      expect(result.output).to include("Target: comeals-staging (#{staging_url})", 'Deploy complete!',
                                       'PUSH deploy (no migrations)')
      expect(deploy.calls).to include("git push #{staging_git} main --force",
                                      'heroku pg:backups:capture -a comeals-staging',
                                      'heroku ps:scale worker=1 -a comeals-staging',
                                      "smoke #{staging_url}")
      expect(deploy.calls_to('curl').map { it.split.last }).to eq([staging_url, "#{staging_url}/api/v1/version"])
      expect(deploy.state[:pushed]).to eq(head)
      expect_production_untouched(result)
    end

    # The commit staging runs is not here, so the deploy fetches it from
    # staging; that fails, so it deploys with maintenance on.
    it 'runs a maintenance deploy on staging, fetching from staging, and never names production' do
      deploy.production(heroku_sha: 'a' * 40)
      deploy.rule('git', "^fetch #{Regexp.escape(staging_git)} main", exit: 128)

      result = deploy.run('--yes', env: staging)

      expect(result.status).to eq(0)
      expect(result.output).to include('Cannot fetch from Heroku — assuming migrations needed',
                                       'MAINTENANCE deploy (has migrations)', 'Deploy complete!')
      expect(deploy.calls).to include("git fetch #{staging_git} main --quiet",
                                      'heroku maintenance:on -a comeals-staging',
                                      'heroku ps:scale web=0 worker=0 -a comeals-staging',
                                      'heroku maintenance:off -a comeals-staging')
      expect_production_untouched(result)
    end

    it 'names staging in the recovery banner when a maintenance deploy fails' do
      deploy.production(heroku_sha: deploy.commits[:first_migration])
      deploy.rule('git', '^push', exit: 1)

      result = deploy.run('--yes', env: staging)

      expect(result.status).to eq(1)
      expect(result.output).to include(recovery_banner, 'heroku maintenance:off -a comeals-staging')
      expect_production_untouched(result)
    end

    it 'needs no heroku git remote' do
      deploy.git('remote', 'remove', 'heroku')

      result = deploy.run('--yes', env: staging)

      expect(result.status).to eq(0)
      expect(result.output).to include("Pushes go to #{staging_git}")
    end

    it 'files no GitHub issue for the break-glass, and says so' do
      result = deploy.run('--yes', env: staging.merge('DEPLOY_WITHOUT_CI' => '1'), input: "break glass\n", tty: true)

      expect(result.status).to eq(0)
      expect(result.output).to include('No follow-up issue for a deploy to comeals-staging')
      expect(deploy.calls_to('gh')).to eq([])
    end

    # The deploy starts the worker dyno, and its jobs send mail. Staging's
    # database holds real residents' email addresses.
    describe 'refusing a staging app that can send mail or push' do
      it 'refuses when COMEALS_STAGING is not set' do
        deploy.production(config: {})

        result = deploy.run('--yes', env: staging)

        expect(result.status).to eq(1)
        expect(result.output).to include('COMEALS_STAGING is not set or is blank on comeals-staging')
        expect_nothing_changed_in_production
      end

      it 'refuses when COMEALS_STAGING is blank' do
        deploy.production(config: { 'COMEALS_STAGING' => ' ' })

        result = deploy.run('--yes', env: staging)

        expect(result.status).to eq(1)
        expect(result.output).to include('COMEALS_STAGING is not set or is blank on comeals-staging')
      end

      it 'refuses when a mail credential is set' do
        deploy.production(config: { 'COMEALS_STAGING' => '1', 'GMAIL_APP_PASSWORD' => 'x' })

        result = deploy.run('--yes', env: staging)

        expect(result.status).to eq(1)
        expect(result.output).to include('GMAIL_APP_PASSWORD is set on comeals-staging — staging must not have it')
        expect_nothing_changed_in_production
      end

      it 'does not run the check on production' do
        deploy.production(config: {})

        deploy.run('--yes')

        expect(deploy.calls_to('heroku').grep(/COMEALS_STAGING|config -a/)).to eq([])
      end
    end
  end
end
