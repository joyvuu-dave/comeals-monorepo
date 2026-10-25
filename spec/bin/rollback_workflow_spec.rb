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
  before { %w[bin/lib/json.sh bin/lib/wait_until_stopped.sh bin/rollback-check bin/smoke].each { sandbox.link(it) } }

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
    let(:diff) { "diff --name-only --no-renames --diff-filter=A #{good} #{bad} -- db/migrate" }

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

  # #248. The rollback runs the old code's release phase, whose db:migrate
  # cannot run a migration that was deleted from db/migrate/. So a backup
  # behind the old code's db/production_schema_version.txt must be
  # refused before the restore, not after it.
  describe 'bin/lib/rollback/check-backup' do
    let(:file) { "#{good}:db/production_schema_version.txt" }
    let(:url) { 'https://backups.example/b245.dump?X-Amz-Signature=secret' }

    before do
      sandbox.rule('git', "cat-file -e #{good}^{commit}")
      sandbox.rule('git', "cat-file -e #{file}")
      sandbox.rule('git', "show #{file}", out: "# The version of the newest migration.\n#\n20261023140000\n")
      sandbox.rule('git', "ls-tree --name-only #{good}:db/migrate", out: ".keep\n")
      sandbox.rule('heroku', "pg:backups:url b245 #{prod}", out: "#{url}\n")
      sandbox.rule('curl', '-sf *', out: 'the backup')
      sandbox.rule('pg_restore', '--data-only --schema=public --table=schema_migrations -f -',
                   out: dump("20261023140000\n20170515164827\n"), capture_stdin: true)
    end

    # What pg_restore writes for schema_migrations alone, around rows.
    def dump(rows)
      "--\n-- PostgreSQL database dump\n--\n\nSET statement_timeout = 0;\n\n" \
        "COPY \"public\".\"schema_migrations\" (\"version\") FROM stdin;\n#{rows}\\.\n\n\n" \
        "--\n-- PostgreSQL database dump complete\n--\n\n"
    end

    def check(env = {})
      sandbox.run_script('bin/lib/rollback/check-backup',
                         env: { 'APP' => 'comeals-monorepo', 'BACKUP' => 'b245', 'TARGET' => 'v612',
                                'TARGET_SHA' => good }.merge(env))
    end

    it 'passes a backup that has run the migration the file names' do
      result = check

      expect(result.exitstatus).to eq(0)
      expect(result.out).to eq(
        "Backup b245 has run 2 migrations, the newest 20261023140000, which is not newer than the newest version\n" \
        "the code of v612 knows (20261023140000).\n" \
        "It is not behind the db/production_schema_version.txt of v612 (20261023140000) either.\n"
      )
      expect(heroku_calls).to eq(["heroku pg:backups:url b245 #{prod}"])
      expect(sandbox.calls_to('curl').map(&:args)).to eq([['-sf', url]])
    end

    # The backup holds residents' personal data. curl hands it straight
    # to pg_restore, which writes out only schema_migrations; no file of
    # it is made.
    it 'streams the backup into pg_restore and keeps no file of it' do
      check

      expect(sandbox.stdin_of('pg_restore')).to eq(['the backup'])
      expect(Dir.children(File.join(sandbox.dir, 'tmp'))).to be_empty
      expect(Dir.children(File.join(sandbox.root, 'tmp'))).to be_empty
    end

    # Anyone with the signed address can download the backup until it
    # expires. In Actions the mask makes the log print *** in its place.
    it 'masks the signed address in Actions, and prints it nowhere else' do
      result = check('GITHUB_ACTIONS' => 'true')

      expect(result.exitstatus).to eq(0)
      expect(result.out.lines.first).to eq("::add-mask::#{url}\n")
      expect(result.out.lines.grep(/X-Amz/)).to eq(["::add-mask::#{url}\n"])
      expect(result.err).not_to include('X-Amz')
    end

    it 'never prints the signed address outside Actions' do
      sandbox.rule('pg_restore', '*', out: dump(''))

      result = check

      expect("#{result.out}#{result.err}").not_to include('X-Amz')
    end

    it 'refuses a backup behind the file, before anything is changed' do
      sandbox.rule('pg_restore', '*', out: dump("20261016130000\n20170515164827\n"))

      result = check

      expect(result.exitstatus).to eq(1)
      expect(result.out).to include(
        'Backup b245 is behind the db/production_schema_version.txt of v612. Its newest migration is ' \
        "20261016130000, but the file says 20261023140000:\n",
        'Backup b245 was not restored, and nothing was changed.',
        '(heroku pg:backups -a comeals-monorepo)'
      )
      expect(heroku_calls).to eq(["heroku pg:backups:url b245 #{prod}"])
    end

    # A commit from before the file was added still holds every migration
    # file, so the old code's db:migrate runs what the backup lacks.
    it 'passes a backup no newer than its migration files when the commit has no version file' do
      sandbox.rule('git', "cat-file -e #{file}", exit: 128)
      sandbox.rule('git', "ls-tree --name-only #{good}:db/migrate",
                   out: "20170515164827_create_communities.rb\n20261023140000_drop_a_column.rb\n")

      result = check

      expect(result.exitstatus).to eq(0)
      expect(result.out).to include('the code of v612 knows (20261023140000).',
                                    'The commit of v612 has no db/production_schema_version.txt. It still holds ' \
                                    'every migration file')
    end

    # Nothing would tell which database such code needs.
    it 'refuses when the commit has no version file and no migration file' do
      sandbox.rule('git', "cat-file -e #{file}", exit: 128)
      sandbox.rule('git', "ls-tree --name-only #{good}:db/migrate", exit: 128, err: 'fatal: not a tree object')

      result = check

      expect(result.exitstatus).to eq(1)
      expect(result.out).to include('The commit of v612 has no db/production_schema_version.txt and no migration ' \
                                    'file, so it is not known')
      expect(heroku_calls).to be_empty
    end

    # A backup with a migration the old code does not know holds a schema
    # made by newer code: the rollback would not undo what it is for.
    context 'when the backup is newer than the code it goes back to' do
      let(:newer) { dump("20261023140000\n20261101120000\n") }

      it 'refuses it, naming the version the code does not know' do
        sandbox.rule('pg_restore', '*', out: newer)

        result = check

        expect(result.exitstatus).to eq(1)
        expect(result.out).to include(
          'Backup b245 has migration 20261101120000, which the code of v612 does not know: the newest version it ' \
          "knows is\n20261023140000.",
          'Backup b245 was not restored, and nothing was changed. Run this again with the backup bin/deploy',
          'took before the deploy that is being undone (its output names it), or with a newer release.'
        )
      end

      it 'refuses it when the commit has no version file too' do
        sandbox.rule('git', "cat-file -e #{file}", exit: 128)
        sandbox.rule('git', "ls-tree --name-only #{good}:db/migrate", out: "20261023140000_drop_a_column.rb\n")
        sandbox.rule('pg_restore', '*', out: newer)

        result = check

        expect(result.exitstatus).to eq(1)
        expect(result.out).to include('Backup b245 has migration 20261101120000, which the code of v612 does not know')
      end
    end

    # The usual undo of a deploy that ran a migration. bin/deploy captures
    # its backup before it pushes, so before the new release's migrations
    # run: that backup has run exactly what the release before knows, and
    # passes. The backup the restore step captures from the database as the
    # new code left it has the new migration, and is refused.
    context 'when undoing a deploy that ran a migration' do
      before do
        sandbox.rule('git', "show #{file}", out: "20261016130000\n")
        sandbox.rule('git', "ls-tree --name-only #{good}:db/migrate",
                     out: ".keep\n20261021140000_create_browser_counts.rb\n20261023120000_drop_a_column.rb\n")
      end

      it 'passes the backup bin/deploy took before the push' do
        sandbox.rule('pg_restore', '*', out: dump("20261016130000\n20261021140000\n20261023120000\n"))

        expect(check.exitstatus).to eq(0)
      end

      it 'refuses a backup taken after the new release migrated' do
        sandbox.rule('pg_restore', '*', out: dump("20261023120000\n20261023140000\n"))

        result = check

        expect(result.exitstatus).to eq(1)
        expect(result.out).to include('Backup b245 has migration 20261023140000, which the code of v612 does not know')
      end
    end

    # Heroku resolves a<number> (scheduled) and b<number> (taken by hand)
    # among the backups of the app given with -a. Anything else can name
    # another app's database.
    it 'takes a scheduled backup id' do
      sandbox.rule('heroku', "pg:backups:url a017 #{prod}", out: "#{url}\n")

      expect(check('BACKUP' => 'a017').exitstatus).to eq(0)
    end

    ['comeals-staging::b042', 'https://example.com/latest.dump', '', 'r022', 'B245', 'b245 x'].each do |backup|
      it "refuses #{backup.inspect} before it asks git or heroku anything" do
        result = check('BACKUP' => backup)

        expect(result.exitstatus).to eq(1)
        expect(result.out).to eq(
          "\"#{backup}\" is not one of the backup ids of comeals-monorepo. It must be an id that heroku " \
          "pg:backups -a comeals-monorepo lists,\n" \
          "like b245: a backup of this app's own database. Nothing was changed.\n"
        )
        expect(sandbox.calls).to be_empty
      end
    end

    # Without this, a commit that was not fetched would look like one
    # from before the version file, and pass.
    it 'refuses when the commit is not in the checkout' do
      sandbox.rule('git', "cat-file -e #{good}^{commit}", exit: 128, err: 'fatal: Not a valid object name')
      sandbox.rule('git', "cat-file -e #{file}", exit: 128)

      result = check

      expect(result.exitstatus).to eq(1)
      expect(result.out).to include("The commit of v612 (#{good}) is not in this checkout. Backup b245 was not " \
                                    'restored; nothing was changed.')
      expect(heroku_calls).to be_empty
    end

    it 'refuses when the file does not hold one version' do
      sandbox.rule('git', "show #{file}", out: "# A comment only.\n")

      result = check

      expect(result.exitstatus).to eq(1)
      expect(result.out).to include('must hold one version of 14 digits. Backup b245 was not restored')
      expect(heroku_calls).to be_empty
    end

    context 'when the backup cannot be read' do
      def expect_refused(result, reason)
        expect(result.exitstatus).to eq(1)
        expect(result.out).to include("Could not read the migrations in backup b245 of comeals-monorepo: #{reason}.",
                                      'So the backup was not restored, and nothing was changed.')
      end

      it 'refuses when heroku cannot give the address' do
        sandbox.rule('heroku', 'pg:backups:url *', err: 'Error: Not found.', exit: 1)

        expect_refused(check, 'heroku pg:backups:url failed')
        expect(sandbox.calls_to('curl')).to be_empty
      end

      it 'refuses an address that is not https' do
        sandbox.rule('heroku', 'pg:backups:url *', out: "Warning: something\n")

        expect_refused(check, 'heroku pg:backups:url did not give an https address')
        expect(sandbox.calls_to('curl')).to be_empty
      end

      # A pg_restore older than the PostgreSQL that made the backup cannot
      # read it.
      it 'refuses when pg_restore fails' do
        sandbox.rule('pg_restore', '*', err: 'pg_restore: error: unsupported version (1.16) in file header', exit: 1)

        expect_refused(check, 'pg_restore exited with 1, and curl with 0')
      end

      # pg_restore stops reading once it wrote the table, and curl then
      # fails to write the rest. That is how a good read ends.
      it 'passes when curl could not write the rest after pg_restore stopped reading' do
        sandbox.rule('curl', '-sf *', exit: 23)

        expect(check.exitstatus).to eq(0)
      end

      it 'refuses when curl fails any other way' do
        sandbox.rule('curl', '-sf *', exit: 56)

        expect_refused(check, 'curl exited with 56')
      end

      it 'refuses a backup with no schema_migrations table' do
        sandbox.rule('pg_restore', '*', out: "--\n-- PostgreSQL database dump\n--\n\n")

        expect_refused(check, 'it has no schema_migrations table')
      end

      it 'refuses when the rows end part way' do
        sandbox.rule('pg_restore', '*',
                     out: "COPY \"public\".\"schema_migrations\" (\"version\") FROM stdin;\n20261023140000\n")

        expect_refused(check, 'its schema_migrations data ended part way')
      end

      it 'refuses a row that is not a version' do
        sandbox.rule('pg_restore', '*', out: dump("20261023140000\nnot a version\n"))

        expect_refused(check, 'schema_migrations holds a row that is not a version')
      end
    end

    # bin/deploy lets a live database with no migration through, because
    # a new database gets its schema from db/structure.sql. A backup put
    # over production is never that.
    it 'refuses a backup that has run no migration' do
      sandbox.rule('pg_restore', '*', out: dump(''))

      result = check

      expect(result.exitstatus).to eq(1)
      expect(result.out).to include('Backup b245 of comeals-monorepo has run no migration, so it is not a copy of ' \
                                    "production's database.")
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
      sandbox.rule('heroku', "pg:psql -c * #{prod}", out: psql_count(0))
      sandbox.rule('sleep')
    end

    # What heroku pg:psql prints for the count of Solid Queue processes
    # with a fresh heartbeat.
    def psql_count(count) = " solid_queue \n-------------\n fresh=#{count}\n(1 row)\n\n"

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
         heroku_calls.grep(/pg:psql/).first,
         "heroku pg:backups:restore b245 DATABASE_URL #{prod} --confirm comeals-monorepo"]
      )
      expect(heroku_calls.grep(/pg:psql/).size).to eq(1)
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

    # bin/deploy leaves web and the worker at 0 when a maintenance deploy
    # stops: a failed release phase, a failed ledger check. A rollback
    # from there must still end with the site serving. With web_count 0,
    # "Start the web dyno" scaled web to 0, found 0 up, and maintenance
    # went off with no web dyno.
    it 'brings web back as one dyno when web was at 0, and says so' do
      sandbox.rule('curl', '* https://api.heroku.com/apps/comeals-monorepo/formation',
                   out: '[{"type":"web","quantity":0},{"type":"worker","quantity":0}]')

      result = restore

      expect(result.exitstatus).to eq(0)
      expect(result.outputs).to eq('web_count' => '1')
      expect(result.out).to include('comeals-monorepo runs 0 web dyno(s) and a worker dyno. Scaling both to 0.',
                                    'Web will come back as 1 dyno, so the site serves after the rollback.')
    end

    # #245. heroku ps can list no worker while a worker process that
    # Heroku restarted still runs Solid Queue. Such a process writes a
    # heartbeat to solid_queue_processes every 60 seconds, so the restore
    # also waits until no row has one from the last 75 seconds.
    it 'reads the Solid Queue heartbeats of the last 75 seconds, in UTC' do
      restore

      sql = sandbox.calls_to('heroku').find { it.args.first == 'pg:psql' }.args
      expect(sql.first(2)).to eq(['pg:psql', '-c'])
      expect(sql.last(2)).to eq(['-a', 'comeals-monorepo'])
      expect(sql[2]).to eq(
        "SELECT 'fresh=' || count(*) AS solid_queue FROM solid_queue_processes " \
        "WHERE last_heartbeat_at > (now() AT TIME ZONE 'UTC') - interval '75 seconds'"
      )
    end

    # Solid Queue writes each heartbeat every process_heartbeat_interval,
    # and production sets no other value than the gem's. The wait must
    # count a row as alive for longer than that, or a running process
    # could look stopped between two heartbeats.
    it 'waits longer than one Solid Queue heartbeat interval' do
      script = Rails.root.join('bin/lib/wait_until_stopped.sh').read
      seconds = Integer(script[/^SOLID_QUEUE_ALIVE_SECONDS=(\d+)$/, 1])

      expect(seconds).to be > SolidQueue.process_heartbeat_interval.to_i
      expect(SolidQueue.process_heartbeat_interval).to eq(60.seconds)
      %w[config/application.rb config/environments/production.rb].each do |file|
        expect(Rails.root.join(file).read).not_to include('process_heartbeat_interval')
      end
    end

    it 'waits while a Solid Queue process still sends heartbeats, then restores' do
      sandbox.rule('heroku', "pg:psql -c * #{prod}", out: psql_count(1), once: true)

      result = restore

      expect(result.exitstatus).to eq(0)
      expect(result.out).to include('1 Solid Queue process(es) sent a heartbeat in the last 75 seconds')
      expect(heroku_calls.grep(/pg:psql/).size).to eq(2)
      expect(heroku_calls.last).to start_with('heroku pg:backups:restore')
      expect(sandbox.calls_to('sleep').map(&:args)).to eq([['5'], ['5']])
    end

    # Production state: maintenance on, web and the worker at 0, the
    # database as the new code left it. The step that says what to do by
    # hand runs next.
    it 'does not restore when a Solid Queue process still sends heartbeats after 3 minutes' do
      sandbox.rule('heroku', "pg:psql -c * #{prod}", out: psql_count(1))

      result = restore

      expect(result.exitstatus).to eq(1)
      expect(result.out).to include(
        '1 Solid Queue process(es) still sent a heartbeat in the last 75 seconds, 3 minutes after ' \
        'web and the worker were scaled to 0.',
        'So the backup was not restored.'
      )
      expect(heroku_calls.grep(/pg:psql/).size).to eq(36)
      expect(heroku_calls.grep(/restore/)).to be_empty
    end

    # A database from before Solid Queue has no solid_queue_processes
    # table. No Solid Queue process can run on it: a process must write
    # its row there to start.
    it 'takes a missing solid_queue_processes table to mean no Solid Queue process runs' do
      sandbox.rule('heroku', "pg:psql -c * #{prod}", exit: 1,
                                                     err: "ERROR:  relation \"solid_queue_processes\" does not exist\n")

      result = restore

      expect(result.exitstatus).to eq(0)
      expect(result.out).to include('The database has no solid_queue_processes table, so no Solid Queue process runs.')
      expect(heroku_calls.last).to start_with('heroku pg:backups:restore')
    end

    # A query that failed says nothing about what runs, so it is asked
    # again, and never read as "nothing runs".
    it 'asks again when the query fails' do
      sandbox.rule('heroku', "pg:psql -c * #{prod}", exit: 1, err: "connection refused\n", once: true)

      result = restore

      expect(result.exitstatus).to eq(0)
      expect(result.out).to include('Could not read solid_queue_processes (connection refused). Asking again.')
      expect(heroku_calls.grep(/pg:psql/).size).to eq(2)
      expect(heroku_calls.last).to start_with('heroku pg:backups:restore')
    end

    it 'does not restore when the query fails for 3 minutes' do
      sandbox.rule('heroku', "pg:psql -c * #{prod}", exit: 1, err: "connection refused\n")

      result = restore

      expect(result.exitstatus).to eq(1)
      expect(result.out).to include(
        'Could not read solid_queue_processes for 3 minutes, so it is not known whether a Solid Queue ' \
        'process still runs. The last error: connection refused',
        'So the backup was not restored.'
      )
      expect(heroku_calls.grep(/restore/)).to be_empty
    end

    # A query that answers but prints no count (say, a psql that prints
    # only a warning) is a failed query too.
    it 'does not take an answer with no count to mean nothing runs' do
      sandbox.rule('heroku', "pg:psql -c * #{prod}", out: "\n")

      result = restore

      expect(result.exitstatus).to eq(1)
      expect(result.out).to include('Could not read solid_queue_processes (no output). Asking again.')
      expect(heroku_calls.grep(/restore/)).to be_empty
    end

    # A failed heroku ps says nothing about what runs either.
    it 'asks heroku ps again when it fails' do
      sandbox.rule('heroku', "ps #{prod} --json", exit: 1, err: "Invalid credentials\n", once: true)

      result = restore

      expect(result.exitstatus).to eq(0)
      expect(heroku_calls.grep(/^heroku ps -a/).size).to eq(3)
      expect(heroku_calls.last).to start_with('heroku pg:backups:restore')
    end

    # Production state: maintenance on, web at 0, the database as the new
    # code left it. The step that says what to do by hand runs next.
    it 'does not restore when a web or worker dyno still runs after 3 minutes' do
      sandbox.rule('heroku', "ps #{prod} --json", out: '[{"type":"worker"}]')

      result = restore

      expect(result.exitstatus).to eq(1)
      expect(result.out).to include('A web or worker dyno still runs 3 minutes after they were scaled to 0.',
                                    'So the backup was not restored.')
      expect(heroku_calls.grep(/restore|pg:psql/)).to be_empty
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
      expect(result.out).to include(
        '  heroku pg:psql -a comeals-monorepo -c "SELECT count(*) FROM solid_queue_processes ' \
        "WHERE last_heartbeat_at > (now() AT TIME ZONE 'UTC') - interval '75 seconds'\"\n  " \
        'heroku pg:backups:restore b245 DATABASE_URL -a comeals-monorepo --confirm comeals-monorepo'
      )
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
      expect(with_token.pluck('if')).to all(end_with("inputs.app == 'comeals-monorepo'"))
    end

    # Once the rollback ran, production runs the old code, and the weekly
    # deploy must be held or it ships the bad sha again. On 2026-10-22 the
    # smoke step's Playwright install waited 11 of the job's 15 minutes on
    # the apt mirror (#240). Had it failed, or had the job run out of time,
    # every step after it would have been skipped: no DEPLOY_HOLD, no
    # marked release note, no follow-up issue. So these steps run before
    # the smoke test, and whenever the rollback itself worked, whatever
    # happened to the steps between them.
    it 'does the bookkeeping whenever the rollback worked, before the smoke test' do
      names = steps.pluck('name')
      with_token = steps.select { it.dig('env', 'GH_TOKEN') }

      expect(with_token.pluck('if'))
        .to all(eq("always() && steps.roll.outcome == 'success' && inputs.app == 'comeals-monorepo'"))
      expect(with_token.map { names.index(it['name']) }).to all(be < names.index('Smoke the rolled-back site'))
    end

    # The smoke test still runs after a bookkeeping step fails: it is the
    # only check that the old code serves.
    it 'smokes the site whenever the rollback worked' do
      smoke = steps.find { it['name'] == 'Smoke the rolled-back site' }

      expect(smoke['if']).to eq("${{ !cancelled() && steps.roll.outcome == 'success' }}")
    end

    # The smoke test signs in with the owner's resident and admin accounts
    # on production. On staging it gets none, and checks the public pages.
    it 'gives the smoke test the sign-ins from the secrets, on production only' do
      smoke = steps.find { it['name'] == 'Smoke the rolled-back site' }

      expect(smoke['env'].except('PLAYWRIGHT_INSTALL_MINUTES')).to eq(
        %w[SMOKE_EMAIL SMOKE_PASSWORD SMOKE_ADMIN_EMAIL SMOKE_ADMIN_PASSWORD].index_with do |name|
          "${{ inputs.app == 'comeals-monorepo' && secrets.#{name} || '' }}"
        end
      )
      expect(steps.reject { it == smoke }.map { it['env'].to_s }.grep(/SMOKE_/)).to eq([])
    end

    # #248. The backup is checked against the release it goes back to
    # before the step that turns maintenance on and restores it, and in
    # every run that restores one.
    it 'checks the backup before the step that restores it' do
      names = steps.pluck('name')
      check = steps.find { it['name'] == 'Check the backup' }
      install = steps.find { it['name'] == 'Install the PostgreSQL 18 client, to read the backup' }
      restore = steps.find { it['id'] == 'restore' }

      expect(check['run']).to eq('bin/lib/rollback/check-backup')
      expect([install, check].pluck('if')).to all(eq(restore['if']))
      expect(names.index(install['name'])).to be < names.index(check['name'])
      expect(names.index(check['name'])).to be < names.index(restore['name'])
      expect(check['env']).to eq('TARGET' => '${{ steps.find.outputs.target }}',
                                 'TARGET_SHA' => '${{ steps.find.outputs.target_sha }}')
    end

    it 'gives no other step a way to write to GitHub' do
      others = steps.reject { it.dig('env', 'GH_TOKEN') }

      expect(others.map { "#{it['run']}#{it['with']}" }.grep(/\bgh |github\.token/)).to eq([])
    end
  end
end
