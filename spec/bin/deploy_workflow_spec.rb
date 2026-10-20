# frozen_string_literal: true

require 'rails_helper'

# The scripts the weekly Deploy workflow (.github/workflows/deploy.yml)
# runs, one per step, with fake heroku, gh, git, curl, claude and the
# rest (spec/support/script_sandbox.rb). The workflow passes each step's
# inputs as variables; the examples pass the same ones.
RSpec.describe 'the Deploy workflow scripts', bash_coverage: BashCoverage.new('spec/bin/deploy_workflow_spec.rb') do
  let(:sandbox) do
    ScriptSandbox.new(fakes: %w[heroku gh git curl claude npm node date sleep],
                      coverage: self.class.metadata[:bash_coverage])
  end
  let(:candidate) { 'c' * 40 }
  let(:live) { 'l' * 40 }
  let(:prod) { '-a comeals-monorepo' }
  let(:apps) { { 'PROD_APP' => 'comeals-monorepo', 'STAGING_APP' => 'comeals-staging' } }

  after { sandbox.cleanup }

  # Holds the scripts BashCoverage::FILES names for this file at 100% of
  # their lines. It runs only when every example in the file ran, so one
  # example on its own can still pass (spec/bin/deploy_spec.rb).
  after(:context) do
    ran_all = self.class.descendant_filtered_examples.size == self.class.descendants.sum { it.examples.size }
    self.class.metadata[:bash_coverage].check! if ran_all
  end

  def heroku_calls = sandbox.call_lines('heroku')

  describe 'bin/lib/deploy/hold-check' do
    def hold(value) = sandbox.run('bin/lib/deploy/hold-check', env: { 'DEPLOY_HOLD' => value })

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
    before { sandbox.fake('git', 'rev-parse HEAD', out: "#{candidate}\n") }

    def compare = sandbox.run('bin/lib/deploy/compare', env: apps)

    it 'goes on when production runs another commit' do
      sandbox.fake('heroku', "config:get HEROKU_SLUG_COMMIT #{prod}", out: "#{live}\n")

      result = compare

      expect(result.exitstatus).to eq(0)
      expect(result.outputs).to eq('candidate' => candidate, 'live' => live, 'proceed' => 'true')
      expect(result.out).to include("Candidate #{candidate}; production runs #{live}.")
    end

    it 'stops the deploy when production already runs the candidate' do
      sandbox.fake('heroku', "config:get HEROKU_SLUG_COMMIT #{prod}", out: "#{candidate}\n")

      result = compare

      expect(result.exitstatus).to eq(0)
      expect(result.outputs['proceed']).to eq('false')
      expect(result.out).to include('nothing to deploy')
    end
  end

  describe 'bin/lib/deploy/green-gate' do
    def gate(runs)
      sandbox.fake('gh', "api repos/{owner}/{repo}/commits/#{candidate}/check-runs --paginate --jq *",
                   out: runs.map { "#{it}\n" }.join)
      sandbox.run('bin/lib/deploy/green-gate', env: { 'CANDIDATE' => candidate })
    end

    it 'passes when every check succeeded, was neutral or was skipped' do
      result = gate(%w[ruby-test|completed|success node-lint|completed|neutral mutant|completed|skipped])

      expect(result.exitstatus).to eq(0)
      expect(result.out).to eq("All CI checks green.\n")
      expect(sandbox.calls_to('gh').first.last).to include('select(.name != "daily-deploy")')
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
      sandbox.fake('git', "log --reverse --format=- %s%n%w(0,2,2)%b #{live}..#{candidate}", out: commits)
      sandbox.fake('heroku', "apps:info #{prod} --json", out: '{"app":{"stack":{"name":"heroku-24"}}}')
      sandbox.fake('heroku', 'apps:info -a comeals-staging --json', out: '{"app":{"build_stack":{"name":"heroku-24"}}}')
      sandbox.fake('npm', 'install -g @anthropic-ai/claude-code')
      sandbox.fake('claude', '-p', out: "## What changed\n- The bills page shows again.\n", capture_stdin: true)
      sandbox.fake('date', '-u +%Y%m%d-%H%M', out: "20261019-1200\n")
    end

    def write_note
      sandbox.run('bin/lib/deploy/write-release-note',
                  env: apps.merge('LIVE' => live, 'CANDIDATE' => candidate, 'ANTHROPIC_API_KEY' => 'test-key'))
    end

    def note = File.read(File.join(sandbox.work, 'note.md'))
    def prompt = sandbox.calls.find { it[:command] == 'claude' }[:stdin]

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
      sandbox.fake('claude', '-p', out: "```markdown\n## What changed\n- A fix.\n```\n")

      write_note

      expect(note).to eq("## What changed\n- A fix.\n")
    end

    it 'takes away only the first line when the fence is not closed' do
      sandbox.fake('claude', '-p', out: "```markdown\n## What changed\n- A fix.\n")

      write_note

      expect(note).to eq("## What changed\n- A fix.\n")
    end

    it 'falls back to the commit list when Claude fails' do
      sandbox.fake('claude', '-p', err: 'API error', exit: 1)

      result = write_note

      expect(result.exitstatus).to eq(0)
      expect(result.err).to eq("Claude call failed — falling back to the commit list.\nAPI error")
      expect(note).to eq("Automatically generated commit list (note generator was unavailable):\n\n#{commits}")
      expect(result.outputs).to eq('tag' => 'deploy-20261019-1200')
    end

    it 'falls back to the commit list when Claude writes nothing' do
      sandbox.fake('claude', '-p')

      write_note

      expect(note).to start_with('Automatically generated commit list')
    end

    context 'when the next release moves to a new stack' do
      before do
        sandbox.fake('heroku', 'apps:info -a comeals-staging --json',
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
        sandbox.fake('claude', '-p', exit: 1)

        write_note

        expect(note).to eq("Automatically generated commit list (note generator was unavailable):\n\n" \
                           "#{fact}\n\n#{commits}")
      end
    end

    it 'leaves the stack out when a probe fails' do
      sandbox.fake('heroku', 'apps:info -a comeals-staging --json', exit: 1)

      result = write_note

      expect(result.exitstatus).to eq(0)
      expect(prompt).not_to include('base image')
    end

    it 'cuts a note longer than GitHub allows and says so' do
      sandbox.fake('claude', '-p', out: "#{'x' * 99}\n" * 1300)

      write_note

      expect(note.bytesize).to be < 125_000
      expect(note).to start_with('x' * 99)
      expect(note).to end_with("\n\n(The note was longer than GitHub allows in a release body, so it\n" \
                               "ends here. The full commit list: git log #{live}..#{candidate})\n")
      expect(note.index("\n\n(The note")).to eq(120_000)
    end
  end

  describe 'bin/lib/deploy/solid-queue-config' do
    def configure(pool:, in_puma:)
      sandbox.fake('heroku', "config:get RAILS_DB_POOL #{prod}", out: "#{pool}\n")
      sandbox.fake('heroku', "config:get SOLID_QUEUE_IN_PUMA #{prod}", out: "#{in_puma}\n")
      sandbox.fake('heroku', "config:set RAILS_DB_POOL=4 SOLID_QUEUE_IN_PUMA=true #{prod}")
      sandbox.run('bin/lib/deploy/solid-queue-config', env: apps)
    end

    def sets = heroku_calls.grep(/config:set/)

    it 'writes nothing when both are already right' do
      result = configure(pool: '5', in_puma: 'true')

      expect(result.exitstatus).to eq(0)
      expect(result.out).to eq("RAILS_DB_POOL=5 and SOLID_QUEUE_IN_PUMA=true are set.\n")
      expect(sets).to be_empty
    end

    [['', ''], %w[3 true], ['4', ''], %w[four true]].each do |pool, in_puma|
      it "sets both when RAILS_DB_POOL is '#{pool}' and SOLID_QUEUE_IN_PUMA is '#{in_puma}'" do
        result = configure(pool:, in_puma:)

        expect(result.exitstatus).to eq(0)
        expect(result.out).to include("(were '#{pool}' and '#{in_puma}')")
        expect(sets).to eq(["heroku config:set RAILS_DB_POOL=4 SOLID_QUEUE_IN_PUMA=true #{prod}"])
      end
    end
  end

  describe 'bin/lib/deploy/promote' do
    before do
      sandbox.fake('heroku', "config:get HEROKU_SLUG_COMMIT #{prod}", out: "#{live}\n")
      sandbox.fake('heroku', 'pipelines:promote -a comeals-staging')
      sandbox.fake('date', '-u +%Y-%m-%dT%H:%M:%S', out: "2026-10-19T12:30:00\n")
    end

    def promote = sandbox.run('bin/lib/deploy/promote', env: apps.merge('CANDIDATE' => candidate))

    it 'promotes the slug staging runs and notes when, and what ran before' do
      sandbox.fake('heroku', 'config:get HEROKU_SLUG_COMMIT -a comeals-staging', out: "#{candidate}\n")

      result = promote

      expect(result.exitstatus).to eq(0)
      expect(result.outputs).to eq('started' => '2026-10-19T12:30:00', 'previous' => live)
      expect(heroku_calls.last).to eq('heroku pipelines:promote -a comeals-staging')
    end

    it 'refuses when staging runs another commit' do
      sandbox.fake('heroku', 'config:get HEROKU_SLUG_COMMIT -a comeals-staging', out: "#{live}\n")

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
      sandbox.fake('curl', "-sf #{version_url}", out: %({"version":"614","commit":"#{candidate}"}))
      sandbox.fake('node', 'tests/smoke/smoke.js')
      sandbox.fake('heroku', "run --exit-code bin/rake deploy:verify_solid_queue #{prod}")
      sandbox.fake('heroku', "logs -n 1500 #{prod}", out: "2026-10-19T12:35:00.1+00:00 app[web.1]: Started GET /\n")
      sandbox.fake('heroku', "rollback #{prod}")
      sandbox.fake('heroku', "releases #{prod} -n 3", out: "v614 Deploy failed\n")
      sandbox.fake('git', diff)
      sandbox.fake('sleep')
    end

    def watch
      sandbox.run('bin/lib/deploy/watch-production', chdir: ScriptSandbox::REPO,
                                                     env: apps.merge('CANDIDATE' => candidate, 'PREVIOUS' => live,
                                                                     'STARTED' => '2026-10-19T12:30:00',
                                                                     'PROD_URL' => 'https://comeals.com'))
    end

    def rollbacks = heroku_calls.grep(/heroku rollback/)

    it 'waits for the candidate, smokes it, checks Solid Queue, watches the logs, and keeps it' do
      sandbox.fake('curl', "-sf #{version_url}", out: %({"version":"613","commit":"#{live}"}), once: true)

      result = watch

      expect(result.exitstatus).to eq(0), result.out + result.err
      expect(result.out).to include("Production serves the candidate.\n")
      expect(result.out).to end_with("No worrying lines in the production logs.\n")
      expect(sandbox.calls_to('sleep')).to eq([['5'], ['180']])
      expect(sandbox.calls.find { it[:command] == 'node' }).to be_truthy
      expect(rollbacks).to be_empty
    end

    context 'when production never serves the candidate' do
      before { sandbox.fake('curl', "-sf #{version_url}", exit: 7) }

      it 'rolls back when the new slug is current' do
        sandbox.fake('heroku', "config:get HEROKU_SLUG_COMMIT #{prod}", out: "#{candidate}\n")

        result = watch

        expect(result.exitstatus).to eq(1)
        expect(result.out).to include("Production never started serving #{candidate} (still ).")
        expect(result.out).to include('v614 Deploy failed')
        expect(result.out).to include('The slug is current but not serving — rolling back.')
        expect(rollbacks).to eq(["heroku rollback #{prod}"])
        expect(sandbox.calls_to('sleep')).to eq([['5']] * 60)
      end

      it 'does not roll back when production still runs the old release' do
        sandbox.fake('heroku', "config:get HEROKU_SLUG_COMMIT #{prod}", out: "#{live}\n")
        sandbox.fake('heroku', "releases #{prod} -n 3", exit: 1)

        result = watch

        expect(result.exitstatus).to eq(1)
        expect(result.out).to include('Production still runs the old release — nothing to roll back.')
        expect(rollbacks).to be_empty
      end
    end

    it 'rolls back when the smoke test fails' do
      sandbox.fake('node', 'tests/smoke/smoke.js', exit: 1)

      result = watch

      expect(result.exitstatus).to eq(1)
      expect(result.out).to include('Smoke failed on production. Rolling back.')
      expect(rollbacks).to eq(["heroku rollback #{prod}"])
    end

    it 'does not roll back only the code when the release added a migration' do
      sandbox.fake('node', 'tests/smoke/smoke.js', exit: 1)
      sandbox.fake('git', diff, out: "db/migrate/20261015000000_add_thing.rb\n")

      result = watch

      expect(result.exitstatus).to eq(1)
      expect(result.out).to include('Not rolling back only the code. Follow docs/runbooks/undo-a-deploy.md.')
      expect(rollbacks).to be_empty
    end

    it 'rolls back when Solid Queue did not come up' do
      sandbox.fake('heroku', "run --exit-code bin/rake deploy:verify_solid_queue #{prod}", exit: 1)

      result = watch

      expect(result.exitstatus).to eq(1)
      expect(result.out).to include('Solid Queue is not running on production. Rolling back.')
      expect(rollbacks).to eq(["heroku rollback #{prod}"])
    end

    it 'rolls back on a worrying log line after the promote, and only on those' do
      sandbox.fake('heroku', "logs -n 1500 #{prod}", out: <<~LOGS)
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
      sandbox.fake('heroku', "logs -n 1500 #{prod}", err: 'Internal server error', exit: 1)

      result = watch

      expect(result.exitstatus).to eq(1)
      expect(result.out).to include('Could not read the production logs')
      expect(result.out).not_to include('No worrying lines')
      expect(rollbacks).to be_empty
    end

    it 'keeps a release whose only worrying lines are from before the promote' do
      sandbox.fake('heroku', "logs -n 1500 #{prod}", out: "2026-10-19T12:29:59.9+00:00 app[web.1]: FATAL old\n")

      expect(watch.exitstatus).to eq(0)
      expect(rollbacks).to be_empty
    end
  end

  describe 'bin/lib/deploy/ping-healthchecks' do
    def ping(url, status)
      sandbox.fake('curl')
      sandbox.run('bin/lib/deploy/ping-healthchecks', env: { 'HC_URL' => url, 'JOB_STATUS' => status })
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
      sandbox.fake('curl', '*', exit: 28)

      result = sandbox.run('bin/lib/deploy/ping-healthchecks',
                           env: { 'HC_URL' => 'https://hc.example.com/abc', 'JOB_STATUS' => 'success' })

      expect(result.exitstatus).to eq(0)
    end
  end
end
