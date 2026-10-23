# frozen_string_literal: true

require 'rails_helper'

# bin/check runs every test, linter and scanner and prints a summary. Here
# every tool it runs is a fake that answers like the real one, so these
# examples test the steps' own logic: what each one counts as a pass, a
# warning or a failure, what it prints, the summary, and the exit code.
# The sandbox holds the few files the script reads itself (the Gemfile,
# .env, the JS file list, app code for the grep steps).
RSpec.describe 'bin/check', bash_coverage: BashCoverage.new('spec/bin/check_spec.rb') do
  include_context 'with a script sandbox'

  let(:sandbox) { new_sandbox(real: %w[python3]) }
  let(:script) { sandbox.link('bin/check') }
  let(:esc) { "\e" }

  # What each tool says when all is well, by its arguments.
  let(:bundle_answers) do
    {
      'exec rails db:migrate:status' => reply("database: comeals_development\n\n up     20261019000000  Add thing\n"),
      'exec rubocop --parallel' => reply("Inspecting 512 files\n\n512 files inspected, no offenses detected\n"),
      'exec rubycritic *' => reply("Score: 84.61\n"),
      'exec brakeman --no-pager -q' => reply(''),
      'exec fasterer' => reply("NOTE: RubyParser warning\n120 files inspected, 0 offenses detected\n"),
      'exec rails routes' => reply("meals GET /meals(.:format) api/v1/meals#index\n"),
      'exec debride *' => reply("These methods MIGHT not be called:\n"),
      'exec database_consistency' => reply("NullConstraintChecker ok Meal date\n"),
      'exec srb tc' => reply("No errors! Great job.\n"),
      'exec bundle audit check --update' => reply("Updating ruby-advisory-db ...\nNo vulnerabilities found\n"),
      'exec rspec' => reply("Randomized with seed 4242\n....\n\n4000 examples, 0 failures\n"),
      'exec rake test:generate_fixtures' => reply("Wrote 12 fixtures\n"),
      'exec annotaterb models' => reply("Model files unchanged.\n"),
      'outdated' => reply("Bundle up to date!\n")
    }
  end
  let(:npm_answers) do
    {
      'run lint' => reply("> comeals@2.0.0 lint\n> eslint .\n"),
      'run typecheck' => reply(''),
      'run format:check' => reply("Checking formatting...\nAll matched files use Prettier code style!\n"),
      'run build' => reply("built in 3.2s\n"),
      'audit' => reply("found 0 vulnerabilities\n"),
      # Vitest colors its summary on CI, between the words and the counts.
      'run test:coverage' => reply("#{esc}[2m Test Files #{esc}[22m #{esc}[1m#{esc}[32m140 passed#{esc}[39m\n" \
                                   "#{esc}[2m      Tests #{esc}[22m #{esc}[1m#{esc}[32m1500 passed#{esc}[39m\n"),
      'run test:e2e' => reply("Running 300 tests\n  300 passed (2.0m)\n"),
      'run test:bin' => reply("✔ passes within budget\nℹ tests 7\nℹ pass 7\nℹ fail 0\n"),
      'outdated' => reply('')
    }
  end
  let(:curl_answers) do
    { '*/ruby/4.0.json' => reply('{"latest":"4.0.7"}'), '*/nodejs/24.json' => reply('{"latest":"24.21.0"}') }
  end
  let(:git_answers) { { 'status --porcelain -- tests/fixtures/' => reply('') } }

  def reply(text, status: 0) = "#{sandbox.says(text)}; exit #{status}"

  before do
    sandbox.link('bin/lib/output.sh')
    sandbox.write('Gemfile', "source 'https://rubygems.org'\n\nruby '4.0.7'\n")
    sandbox.write('.debride_whitelist', "# why\nperform\n")
    sandbox.write('docs/agents/frontend-js-files.txt', "# the list\napp/frontend/src/old.jsx\n")
    sandbox.write('app/frontend/src/old.jsx')
    sandbox.write('app/frontend/src/new.ts')
    sandbox.write('app/models/community.rb', "def today = Time.zone.today\n")
    sandbox.write('app/models/meal.rb', "class Meal; end\n")
    sandbox.write('app/services/settlement.rb', "class Settlement; end\n")
    sandbox.write('app/controllers/api/meals_controller.rb', "class MealsController; end\n")
    sandbox.write('lib/tasks/billing.rake', "task :x\n")
    sandbox.write('db/seeds.rb', "Community.first\n")
    sandbox.fake('ruby', 'printf 4.0.7')
    sandbox.fake('node', 'echo v24.21.0')
    sandbox.fake('gitleaks')
    sandbox.fake_script('bin/tapioca')
    sandbox.fake_script('bin/bundle-budget', "echo 'ok     first load: 180.7 KB gzipped (budget 190 KB)'")
    sandbox.fake_script('bin/visual-coverage', "echo 'Markup branches : 100%'")
    sandbox.fake_script('bin/test-integration', "echo '  95 passed (1.5m)'")
  end

  # bundle, npm, git: answers that take the place of the passing ones.
  # curl: all of curl's answers.
  # steps: the step names to run only those, as CI does.
  def run_check(*steps, bundle: {}, npm: {}, curl: nil, git: {})
    sandbox.fake('bundle', sandbox.answers(bundle_answers.merge(bundle)), notes: %w[RAILS_ENV])
    sandbox.fake('npm', sandbox.answers(npm_answers.merge(npm)), notes: %w[E2E_SKIP_BUILD])
    sandbox.fake('curl', sandbox.answers(curl || curl_answers, otherwise: 'exit 22'))
    sandbox.fake('git', sandbox.answers(git_answers.merge(git), otherwise: 'exit 1'))
    sandbox.run(script, *steps)
  end

  # The summary's line for one check, with its colored mark taken out.
  def summary_line(output, name)
    plain = output.gsub(/\e\[[0-9;]*m/, '')
    summary = plain[plain.index("  Summary\n")..]
    summary.lines.find { |line| line =~ /\A    . +#{Regexp.escape(name)} / }&.strip
  end

  # The lines a step printed, from its ==> heading to the next one.
  def step_output(output, title)
    plain = output.gsub(/\e\[[0-9;]*m/, '')
    start = plain.index("==> #{title}\n")
    finish = plain.index('==> ', start + 4) || plain.index('====', start)
    plain[start...finish]
  end

  describe 'when every check passes' do
    subject(:result) { run_check }

    it 'exits 0 and lists every check in the summary, in order' do
      expect(result).to be_success, result.output
      plain = result.output.gsub(/\e\[[0-9;]*m/, '')
      summary = plain[plain.index("  Summary\n")..].lines.grep(/\A    [✓✗⚠ℹ] /).map(&:rstrip)
      expect(summary).to eq([
                              '    ✓  Ruby version         4.0.7 (latest)',
                              '    ✓  Node version         24.21.0 (latest)',
                              '    ✓  Migrations           up to date',
                              '    ✓  RuboCop              512 files inspected, no offenses detected',
                              '    ✓  RubyCritic           Score: 84.61',
                              '    ✓  Brakeman             0 warnings',
                              '    ✓  Fasterer             120 files inspected, 0 offenses detected',
                              '    ✓  Debride              no suspects',
                              '    ✓  Database consistency models and schema agree',
                              '    ✓  ESLint               clean',
                              '    ✓  TypeScript           no type errors',
                              '    ✓  Sorbet               no type errors',
                              '    ✓  RBI files            up to date',
                              '    ✓  Prettier             all formatted',
                              '    ✓  TODO markers         none in money-path code',
                              '    ✓  App-zone dates       none outside Community#today',
                              '    ✓  New JS files         none',
                              '    ✓  Bundle budget        first load: 180.7 KB gzipped',
                              '    ✓  gitleaks             no secrets',
                              '    ✓  bundle audit         no vulnerabilities',
                              '    ✓  npm audit            no vulnerabilities',
                              '    ✓  RSpec                4000 examples, 0 failures, seed 4242',
                              '    ✓  Vitest               Test Files  140 passed, Tests  1500 passed',
                              '    ✓  Node scripts         7 tests passed',
                              '    ✓  API fixtures         no drift',
                              '    ✓  Annotations          no drift',
                              '    ✓  Playwright           300 passed',
                              '    ✓  Screen states        100%',
                              '    ✓  Integration          95 passed',
                              '    ✓  Gem freshness        all current',
                              '    ✓  npm freshness        all current'
                            ])
      expect(plain).to include("  All checks passed.\n")
      expect(plain).to match(/    Completed in 0m \d+s\n\z/)
    end

    it 'runs each tool with the arguments and settings the step names' do
      result
      expect(sandbox.call_lines).to include(
        'ruby -e print RUBY_VERSION', 'curl -sf https://endoflife.date/api/ruby/4.0.json',
        'curl -sf https://endoflife.date/api/nodejs/24.json',
        'bundle exec rubycritic app lib --no-browser --format console --minimum-score 80',
        'bin/tapioca gem --verify', 'bin/tapioca dsl --verify', 'bin/bundle-budget',
        'gitleaks git . --no-banner --redact', 'bin/visual-coverage', 'bin/test-integration'
      )
      debride = sandbox.calls_to('bundle').find { |call| call.args[1] == 'debride' }
      expect(debride.args[2..4]).to eq(['--rails', '--whitelist', debride.args[4]])
      expect(debride.args[5..]).to eq(%w[app lib db/seeds.rb config/initializers config/routes.rb])
      env = sandbox.calls_to('bundle').to_h { |call| [call.args[1..2].join(' '), call.env] }
      expect(env).to include('rails db:migrate:status' => { 'RAILS_ENV' => 'development' },
                             'database_consistency' => { 'RAILS_ENV' => 'test' },
                             'rake test:generate_fixtures' => { 'RAILS_ENV' => 'test' },
                             'annotaterb models' => { 'RAILS_ENV' => 'test' })
      expect(sandbox.calls_to('npm').find { |call| call.args == %w[run test:e2e] }.env)
        .to eq('E2E_SKIP_BUILD' => '1')
    end

    # The whitelist debride reads is .debride_whitelist plus every action
    # name in `rails routes`, in a temporary file that is removed after.
    it 'gives debride the whitelist and the route action names' do
      sandbox.fake('bundle', sandbox.answers(bundle_answers.merge(
                                               'exec debride *' => "cp \"$5\" #{sandbox.dir}/whitelist-seen"
                                             )))
      sandbox.fake('npm', sandbox.answers(npm_answers))
      sandbox.fake('curl', sandbox.answers(curl_answers))
      sandbox.fake('git', sandbox.answers(git_answers))
      sandbox.run(script)

      expect(File.read(File.join(sandbox.dir, 'whitelist-seen'))).to eq("# why\nperform\nindex\n")
      whitelist = sandbox.calls_to('bundle').find { |call| call.args[1] == 'debride' }.args[4]
      expect(File).not_to exist(whitelist)
    end
  end

  describe 'Ruby and Node versions' do
    it 'fails when the running Ruby is not the one the Gemfile names' do
      sandbox.fake('ruby', 'printf 4.0.6')

      result = run_check

      expect(result.exitstatus).to eq(1)
      expect(summary_line(result.output, 'Ruby version')).to eq('✗  Ruby version         4.0.6 (Gemfile wants 4.0.7)')
      expect(sandbox.call_lines).not_to include('curl -sf https://endoflife.date/api/ruby/4.0.json')
    end

    it 'warns when a newer patch release is out' do
      result = run_check(curl: { '*/ruby/4.0.json' => reply('{"latest":"4.0.8"}'),
                                 '*/nodejs/24.json' => reply('{"latest":"24.22.0"}') })

      expect(result).to be_success, result.output
      expect(summary_line(result.output, 'Ruby version')).to eq('⚠  Ruby version         4.0.7 (latest: 4.0.8)')
      expect(summary_line(result.output, 'Node version')).to eq('⚠  Node version         24.21.0 (latest: 24.22.0)')
      expect(result.output).to include('4.0.7 installed — 4.0.8 available', '24.21.0 installed — 24.22.0 available')
      expect(result.output).to include('All checks passed with 2 warning(s).')
    end

    # endoflife.date can take a day or more to list a new release, so the
    # running version can be newer than its "latest".
    it 'passes, and does not offer an older release, when the running version is newer than the list' do
      result = run_check(curl: { '*/ruby/4.0.json' => reply('{"latest":"4.0.6"}'),
                                 '*/nodejs/24.json' => reply('{"latest":"24.9.0"}') })

      expect(result).to be_success, result.output
      expect(summary_line(result.output, 'Ruby version')).to eq('✓  Ruby version         4.0.7 (newer than 4.0.6)')
      expect(summary_line(result.output, 'Node version')).to eq('✓  Node version         24.21.0 (newer than 24.9.0)')
      expect(result.output).not_to include('available')
      expect(result.output).to include('All checks passed.')
    end

    it 'passes without the latest release when the network is down' do
      result = run_check(curl: { '*' => 'exit 6' })

      expect(result).to be_success, result.output
      expect(summary_line(result.output, 'Ruby version')).to eq('✓  Ruby version         4.0.7')
      expect(summary_line(result.output, 'Node version')).to eq('✓  Node version         24.21.0')
      expect(step_output(result.output, 'Node.js version'))
        .to include('Could not check latest patch (network unavailable)')
    end
  end

  describe 'Database migrations' do
    let(:pending) do
      reply("database: comeals_development\n\n up     20261018000000  Old\n  down    20261019000000  New\n")
    end

    it 'fails and lists the migrations that are not run' do
      result = run_check(bundle: { 'exec rails db:migrate:status' => pending })

      expect(result.exitstatus).to eq(1)
      expect(step_output(result.output, 'Database migrations'))
        .to include('✗ Pending migrations detected', '      down    20261019000000  New')
      expect(summary_line(result.output, 'Migrations')).to eq('✗  Migrations           pending')
    end

    # A worktree migrates only its own test database.
    it 'checks the test database in a worktree, whose .env sets TEST_DB_SUFFIX' do
      sandbox.write('.env', "VITE_PUSHER_KEY=x\nTEST_DB_SUFFIX=_task\n")

      run_check

      status = sandbox.calls_to('bundle').find { |call| call.args.include?('db:migrate:status') }
      expect(status.env).to eq('RAILS_ENV' => 'test')
    end

    it 'checks the development database when .env has no TEST_DB_SUFFIX' do
      sandbox.write('.env', "VITE_PUSHER_KEY=x\n")

      run_check

      status = sandbox.calls_to('bundle').find { |call| call.args.include?('db:migrate:status') }
      expect(status.env).to eq('RAILS_ENV' => 'development')
    end
  end

  describe 'static analysis that fails' do
    it 'shows what each failing tool found' do
      result = run_check(
        bundle: {
          'exec rubocop --parallel' => reply("app/models/meal.rb:3:5: C: Style/Thing: Use the other thing.\n  " \
                                             "meal.thing\n512 files inspected, 1 offense detected\n", status: 1),
          'exec brakeman --no-pager -q' => reply("Security Warnings: 2\n+------+\n| SQL  |\n+------+\n", status: 3),
          'exec fasterer' => reply("app/models/meal.rb:4 Hash#fetch with second argument is slower\n" \
                                   "120 files inspected, 1 offense detected\n", status: 1),
          'exec debride *' => reply("These methods MIGHT not be called:\n\nMeal\n  old_thing   app/models/meal.rb:9\n"),
          'exec database_consistency' => reply("NullConstraintChecker fail Meal date column is required\n",
                                               status: 1),
          'exec srb tc' => reply("app/models/meal.rb:3: Method `x` does not exist\nErrors: 1\n", status: 1)
        },
        npm: {
          'run lint' => reply("> comeals@2.0.0 lint\n\n/app/a.jsx\n  3:1  error  no-unused-vars\n", status: 1),
          'run typecheck' => reply("src/a.ts(3,1): error TS2322: Type 'x'.\nsrc/b.ts(4,1): error TS2322: y\n",
                                   status: 2),
          'run format:check' => reply("[warn] app/a.jsx\n[warn] Code style issues found. Run Prettier.\n", status: 1)
        }
      )

      expect(result.exitstatus).to eq(1)
      out = result.output
      expect(step_output(out, 'RuboCop'))
        .to eq("==> RuboCop\n    ✗ 512 files inspected, 1 offense detected\n" \
               "app/models/meal.rb:3:5: C: Style/Thing: Use the other thing.\n\n")
      expect(step_output(out, 'Brakeman')).to include('✗ 2 security warning(s)', "+------+\n| SQL  |\n")
      expect(step_output(out, 'Fasterer')).to include('✗ 120 files inspected, 1 offense detected',
                                                      'app/models/meal.rb:4 Hash#fetch')
      expect(step_output(out, 'Debride'))
        .to include('✗ 1 method(s) without a caller', "Meal\n  old_thing   app/models/meal.rb:9\n")
      expect(step_output(out, 'Database consistency')).to include('✗ 1 check(s) where a model and the schema disagree',
                                                                  'NullConstraintChecker fail Meal date')
      expect(step_output(out, 'ESLint')).to include('✗ Issues found', '3:1  error  no-unused-vars')
      expect(step_output(out, 'ESLint')).not_to include('> comeals@2.0.0 lint')
      expect(step_output(out, 'TypeScript')).to include('✗ 2 type error(s)', 'src/b.ts(4,1): error TS2322')
      expect(step_output(out, 'Sorbet')).to include('✗ 1 type error(s)', 'app/models/meal.rb:3: Method')
      expect(step_output(out, 'Prettier')).to include("✗ Formatting issues\n[warn] app/a.jsx\n")
      expect(step_output(out, 'Prettier')).not_to include('Code style issues')
      names = ['RuboCop', 'Brakeman', 'Fasterer', 'Debride', 'Database consistency', 'ESLint', 'TypeScript',
               'Sorbet', 'Prettier']
      expect(names.map { |name| summary_line(out, name) }).to eq([
                                                                   '✗  RuboCop              512 files inspected, ' \
                                                                   '1 offense detected',
                                                                   '✗  Brakeman             2 warnings',
                                                                   '✗  Fasterer             120 files inspected, ' \
                                                                   '1 offense detected',
                                                                   '✗  Debride              1 suspects',
                                                                   '✗  Database consistency 1 disagreements',
                                                                   '✗  ESLint               issues found',
                                                                   '✗  TypeScript           2 type error(s)',
                                                                   '✗  Sorbet               1 type error(s)',
                                                                   '✗  Prettier             formatting issues'
                                                                 ])
      expect(out).to include('9 check(s) failed.')
    end

    it 'fails a tool that stopped before it printed its count' do
      result = run_check(
        bundle: {
          'exec brakeman --no-pager -q' => reply("cannot parse\n", status: 1),
          'exec fasterer' => reply("crashed\n", status: 1),
          'exec database_consistency' => reply("could not connect\n", status: 1),
          'exec srb tc' => reply("sorbet crashed\n", status: 1)
        }
      )

      expect(result.exitstatus).to eq(1)
      expect(summary_line(result.output, 'Brakeman')).to eq('✗  Brakeman             ? warnings')
      expect(summary_line(result.output, 'Fasterer')).to eq('✗  Fasterer             no summary')
      expect(step_output(result.output, 'Fasterer')).to include('✗ fasterer produced no summary')
      expect(summary_line(result.output, 'Database consistency')).to eq('✗  Database consistency 0 disagreements')
      expect(summary_line(result.output, 'Sorbet')).to eq('✗  Sorbet               ? type error(s)')
    end

    describe 'RubyCritic' do
      it 'fails below the minimum score and names the worst files' do
        result = run_check(bundle: { 'exec rubycritic *' => reply("Meal:\n  Rating: F\nMealLedger:\n  Rating: A\n" \
                                                                  "Score (78.3) is below the minimum 80.0\n",
                                                                  status: 1) })

        expect(step_output(result.output, 'RubyCritic'))
          .to eq("==> RubyCritic\n    ✗ Score: 78.3 — below the minimum of 80\nMeal:\n  Rating: F\n\n")
        expect(summary_line(result.output, 'RubyCritic')).to eq('✗  RubyCritic           Score: 78.3 (minimum: 80)')
      end

      it 'fails when it printed no score' do
        result = run_check(bundle: { 'exec rubycritic *' => reply("undefined method\nfrom flog.rb:3\n", status: 1) })

        expect(step_output(result.output, 'RubyCritic'))
          .to include('✗ rubycritic produced no score (it may have crashed)', "undefined method\nfrom flog.rb:3\n")
        expect(summary_line(result.output, 'RubyCritic')).to eq('✗  RubyCritic           no score produced')
      end
    end

    it 'fails when the RBI files are stale, and lists what tapioca would change' do
      sandbox.fake_script('bin/tapioca', sandbox.answers({ 'dsl --verify' => reply(
        "Checking for out-of-date RBIs...\n  create  sorbet/rbi/dsl/meal.rbi\nRBI files are out-of-date\n", status: 1
      ) }))

      result = run_check

      expect(step_output(result.output, 'RBI files'))
        .to include('✗ RBI files are out of date', "  create  sorbet/rbi/dsl/meal.rbi\n")
      expect(summary_line(result.output, 'RBI files'))
        .to eq('✗  RBI files            stale — run bin/tapioca gem && bin/tapioca dsl')
    end

    it 'does not run the dsl check when the gem check fails' do
      sandbox.fake_script('bin/tapioca', 'exit 1')

      result = run_check

      expect(sandbox.call_lines.grep(/tapioca/)).to eq(['bin/tapioca gem --verify'])
      expect(summary_line(result.output, 'RBI files')).to start_with('✗')
    end
  end

  describe 'the checks that read the code' do
    it 'fails on a TODO marker in money-path code, and on a date read from the app zone' do
      sandbox.write('app/services/settlement.rb', "# TODO: round later\nx = Date.today\n")

      result = run_check

      expect(step_output(result.output, 'TODO markers'))
        .to include('✗ Markers found in money-path code', 'app/services/settlement.rb:1:# TODO: round later')
      expect(step_output(result.output, 'App-zone dates'))
        .to include('✗ Date read from the app zone (use Community#today)',
                    'app/services/settlement.rb:2:x = Date.today')
      expect(summary_line(result.output, 'TODO markers')).to eq('✗  TODO markers         markers in money-path code')
      expect(summary_line(result.output, 'App-zone dates')).to eq('✗  App-zone dates       app-zone date reads')
    end

    it 'does not count a word that only contains TODO' do
      sandbox.write('app/models/todo_list.rb', "TODOS = 1\n")

      expect(summary_line(run_check.output, 'TODO markers')).to start_with('✓')
    end

    it 'fails on a .jsx file that is not on the list, and on a listed file that is gone' do
      sandbox.write('app/frontend/src/brand_new.jsx')
      sandbox.write('docs/agents/frontend-js-files.txt', "# the list\napp/frontend/src/converted.js\n" \
                                                         "app/frontend/src/old.jsx\n")

      result = run_check

      expect(step_output(result.output, 'New JS files'))
        .to include("✗ New .js/.jsx file(s): write new frontend code in TypeScript (ADR 0001)\n" \
                    "app/frontend/src/brand_new.jsx\n",
                    "✗ Converted file(s) still listed in docs/agents/frontend-js-files.txt; remove them\n" \
                    "app/frontend/src/converted.js\n")
      expect(summary_line(result.output, 'New JS files')).to eq('✗  New JS files         list out of date')
    end

    it 'fails on a listed file that is gone, alone' do
      sandbox.write('docs/agents/frontend-js-files.txt', "app/frontend/src/converted.js\napp/frontend/src/old.jsx\n")

      out = step_output(run_check.output, 'New JS files')

      expect(out).to include('✗ Converted file(s) still listed')
      expect(out).not_to include('New .js/.jsx file(s)')
    end
  end

  describe 'Bundle budget' do
    it 'fails over budget and shows both numbers' do
      sandbox.fake_script('bin/bundle-budget', "echo 'ok     first load: 180.7 KB gzipped (budget 190 KB)'; " \
                                               "echo 'OVER   total     : 300.1 KB gzipped (budget 295 KB)'; exit 1")

      result = run_check

      expect(step_output(result.output, 'Bundle budget'))
        .to eq("==> Bundle budget\n    ✗ Over budget\n      " \
               "ok     first load: 180.7 KB gzipped (budget 190 KB)\n      " \
               "OVER   total     : 300.1 KB gzipped (budget 295 KB)\n\n")
      expect(summary_line(result.output, 'Bundle budget')).to eq('✗  Bundle budget        over budget')
    end

    it 'fails without measuring when the build fails' do
      result = run_check(npm: { 'run build' => reply("error during build\n", status: 1) })

      expect(sandbox.call_lines).not_to include('bin/bundle-budget')
      expect(summary_line(result.output, 'Bundle budget')).to eq('✗  Bundle budget        over budget')
    end

    it 'says unknown when the passing output has no first-load line' do
      sandbox.fake_script('bin/bundle-budget')

      expect(summary_line(run_check.output, 'Bundle budget')).to eq('✓  Bundle budget        unknown gzipped')
    end
  end

  describe 'security' do
    it 'fails when gitleaks is not installed' do
      File.delete(File.join(sandbox.fakebin, 'gitleaks'))

      result = run_check

      expect(step_output(result.output, 'gitleaks')).to include('✗ gitleaks is not installed (bin/setup installs it')
      expect(summary_line(result.output, 'gitleaks')).to eq('✗  gitleaks             not installed')
    end

    it 'fails when gitleaks finds a secret, and shows the finding without the value' do
      sandbox.fake('gitleaks', "#{sandbox.says("Finding: KEY=REDACTED\nSecret: REDACTED\nRuleID: generic\n" \
                                               "File: config/x.rb\nLine: 3\nCommit: abc123\nEntropy: 4.1\n")}; exit 1")

      result = run_check

      expect(step_output(result.output, 'gitleaks'))
        .to eq("==> gitleaks\n    ✗ Secrets found\nFinding: KEY=REDACTED\nSecret: REDACTED\nRuleID: generic\n" \
               "File: config/x.rb\nLine: 3\nCommit: abc123\n\n")
      expect(summary_line(result.output, 'gitleaks')).to eq('✗  gitleaks             secrets found')
    end

    it 'warns, and does not fail, when only the advisory update failed' do
      result = run_check(bundle: { 'exec bundle audit check --update' => reply(
        "Updating ruby-advisory-db ...\nfailed to update: lock held\nNo vulnerabilities found\n", status: 1
      ) })

      expect(result).to be_success, result.output
      expect(step_output(result.output, 'bundle audit'))
        .to include('⚠ Advisory database update failed; gems checked against the cached copy', 'failed to update')
      expect(summary_line(result.output, 'bundle audit'))
        .to eq('⚠  bundle audit         advisory db update failed, cached copy clean')
    end

    it 'fails on a vulnerable gem or package' do
      result = run_check(
        bundle: { 'exec bundle audit check --update' => reply("Updating ruby-advisory-db ...\n\nName: rack\n" \
                                                              "Vulnerabilities found!\n", status: 1) },
        npm: { 'audit' => reply("axios  <1.0\nSeverity: high\n1 high severity vulnerability\n", status: 1) }
      )

      expect(step_output(result.output, 'bundle audit'))
        .to eq("==> bundle audit\n    ✗ Vulnerable gems found\nName: rack\nVulnerabilities found!\n\n")
      expect(step_output(result.output, 'npm audit')).to include('✗ Vulnerable packages found', 'Severity: high')
      expect(summary_line(result.output, 'bundle audit')).to eq('✗  bundle audit         vulnerabilities found')
      expect(summary_line(result.output, 'npm audit')).to eq('✗  npm audit            vulnerabilities found')
    end
  end

  describe 'RSpec' do
    it 'fails with the failures and the seed to run them again' do
      result = run_check(bundle: { 'exec rspec' => reply(
        "Randomized with seed 77\n..F\n\nFailures:\n\n  1) Meal works\n     expected 1\n\n" \
        "Finished in 3 seconds\n4000 examples, 1 failure\n\nRandomized with seed 77\n", status: 1
      ) })

      out = step_output(result.output, 'RSpec')
      expect(out).to include('✗ 4000 examples, 1 failure',
                             'Randomized with seed 77. Run the same order again: bundle exec rspec --seed 77',
                             "Failures:\n\n  1) Meal works\n     expected 1\n\nFinished in 3 seconds\n")
      expect(summary_line(result.output, 'RSpec')).to eq('✗  RSpec                4000 examples, 1 failure, seed 77')
    end

    it 'shows the last lines when it failed with no failing example, such as coverage below 100%' do
      result = run_check(bundle: { 'exec rspec' => reply(
        "Randomized with seed 9\n....\n4000 examples, 0 failures\nLine coverage (99.9%) is below the expected " \
        "minimum coverage (100.00%).\nSimpleCov failed with exit 2\n", status: 2
      ) })

      out = step_output(result.output, 'RSpec')
      expect(out).to include('Line coverage (99.9%) is below', 'SimpleCov failed with exit 2')
      expect(out).not_to include("\n....\n")
    end

    it 'gives no seed when rspec stopped before running an example' do
      result = run_check(bundle: { 'exec rspec' => reply("An error occurred while loading spec_helper.\n", status: 1) })

      expect(step_output(result.output, 'RSpec')).not_to include('Randomized with seed')
      expect(summary_line(result.output, 'RSpec')).to eq('✗  RSpec')
    end

    it 'passes without a seed when rspec printed none' do
      result = run_check(bundle: { 'exec rspec' => reply("4000 examples, 0 failures\n") })

      expect(summary_line(result.output, 'RSpec')).to eq('✓  RSpec                4000 examples, 0 failures')
    end
  end

  describe 'Vitest' do
    it 'fails with the end of its output' do
      result = run_check(npm: { 'run test:coverage' => reply("FAIL tests/unit/a.test.js\nERROR: Coverage for " \
                                                             "lines (99%) does not meet threshold (100%)\n",
                                                             status: 1) })

      expect(step_output(result.output, 'Vitest')).to include('✗ Failures detected', 'does not meet threshold')
      expect(summary_line(result.output, 'Vitest')).to eq('✗  Vitest               failures')
    end

    it 'says unknown when it printed no counts' do
      result = run_check(npm: { 'run test:coverage' => reply("no tests\n") })

      expect(summary_line(result.output, 'Vitest')).to eq('✓  Vitest               unknown')
    end
  end

  describe 'Node scripts' do
    it 'fails on a failed test or coverage below 100%, and shows which' do
      result = run_check(npm: { 'run test:bin' => reply("✖ stops when there is no build\nℹ pass 6\n" \
                                                        'ℹ Error: 90.00% line coverage does not meet threshold ' \
                                                        "of 100%.\n", status: 1) })

      expect(step_output(result.output, 'Node scripts'))
        .to eq("==> Node scripts\n    ✗ Failures, or bin/bundle-budget below 100% coverage\n" \
               "✖ stops when there is no build\nℹ Error: 90.00% line coverage does not meet threshold of 100%.\n\n")
      expect(summary_line(result.output, 'Node scripts')).to eq('✗  Node scripts         failures or coverage')
    end

    it 'says ? when the run printed no count' do
      result = run_check(npm: { 'run test:bin' => reply('') })

      expect(summary_line(result.output, 'Node scripts')).to eq('✓  Node scripts         ? tests passed')
    end
  end

  describe 'API fixtures and annotations' do
    it 'fails when the fixtures could not be made, or the annotations could not be written' do
      result = run_check(bundle: { 'exec rake test:generate_fixtures' => reply("PG::ConnectionBad\n", status: 1),
                                   'exec annotaterb models' => reply("annotaterb: no database\n", status: 1) })

      expect(step_output(result.output, 'API fixtures'))
        .to include('✗ rake test:generate_fixtures failed', 'PG::ConnectionBad')
      expect(step_output(result.output, 'Annotations')).to include('✗ annotaterb failed', 'annotaterb: no database')
      expect(summary_line(result.output, 'API fixtures')).to eq('✗  API fixtures         generation failed')
      expect(summary_line(result.output, 'Annotations')).to eq('✗  Annotations          annotaterb failed')
      expect(sandbox.calls_to('git')).to be_empty
    end

    it 'fails when the made fixtures differ from the committed ones, or annotaterb changed a file' do
      result = run_check(
        git: { 'status --porcelain -- tests/fixtures/' => reply(" M tests/fixtures/meal.json\n") },
        bundle: { 'exec annotaterb models' => reply("Annotated (1): app/models/meal.rb\n") }
      )

      expect(step_output(result.output, 'API fixtures'))
        .to eq("==> API fixtures\n    ✗ Fixtures are stale — commit the regenerated files\n       " \
               "M tests/fixtures/meal.json\n\n")
      expect(step_output(result.output, 'Annotations'))
        .to include('✗ Annotations are stale', 'Annotated (1): app/models/meal.rb')
      expect(summary_line(result.output, 'API fixtures')).to eq('✗  API fixtures         stale fixtures')
      expect(summary_line(result.output, 'Annotations')).to eq('✗  Annotations          stale annotations')
    end
  end

  describe 'the browser suites' do
    let(:failed_run) do
      <<~OUT
        Running 300 tests

          1) [chromium] › tests/e2e/meal.spec.js:10:3 › signs up

            Error: expect(received).toBe(expected)
            Expected: 2

              attachment #1: screenshot (image/png)
              test-results/meal/shot.png

          2) [webkit] › tests/e2e/calendar.spec.js:4:3 › shows the month

            TimeoutError: waiting for locator

          2 failed
          1 flaky
          297 passed (2.1m)
      OUT
    end

    it 'fails a suite with failed tests, and prints each failure up to its attachments' do
      sandbox.fake_script('bin/test-integration', "#{sandbox.says(failed_run)}; exit 1")

      result = run_check(npm: { 'run test:e2e' => reply(failed_run, status: 1) })

      expect(step_output(result.output, 'Playwright')).to eq(<<~OUT)
        ==> Playwright
          1 flaky
          297 passed (2.1m)
            ✗ 2 failed
          1) [chromium] › tests/e2e/meal.spec.js:10:3 › signs up
            Error: expect(received).toBe(expected)
            Expected: 2
          2) [webkit] › tests/e2e/calendar.spec.js:4:3 › shows the month
            TimeoutError: waiting for locator
            Traces and screenshots: test-results/

      OUT
      expect(summary_line(result.output, 'Playwright')).to eq('✗  Playwright           2 failed')
      expect(step_output(result.output, 'Integration tests'))
        .to include('✗ 2 failed', '1) [chromium]', 'Traces and screenshots: test-results/integration/')
      expect(summary_line(result.output, 'Integration')).to eq('✗  Integration          2 failed')
    end

    it 'names a flaky test in a run that passed' do
      result = run_check(npm: { 'run test:e2e' => reply("  1 flaky\n    [webkit] › a.spec.js › b\n  299 passed\n") })

      expect(summary_line(result.output, 'Playwright')).to eq('✓  Playwright           299 passed, 1 flaky')
      expect(step_output(result.output, 'Playwright')).to include("  1 flaky\n    [webkit] › a.spec.js › b\n")
    end

    it 'says failures and unknown when a suite stopped before it counted anything' do
      sandbox.fake_script('bin/test-integration', 'echo "port 21060 is already in use"; exit 1')

      result = run_check(npm: { 'run test:e2e' => reply("Error: no build\n", status: 1) })

      expect(summary_line(result.output, 'Playwright')).to eq('✗  Playwright           failures')
      expect(summary_line(result.output, 'Integration')).to eq('✗  Integration          failures')
    end

    it 'says unknown for a passing suite that printed no count' do
      sandbox.fake_script('bin/test-integration')

      result = run_check(npm: { 'run test:e2e' => reply('') })

      expect(summary_line(result.output, 'Playwright')).to eq('✓  Playwright           unknown')
      expect(summary_line(result.output, 'Integration')).to eq('✓  Integration          unknown')
    end

    it 'fails the screen states below the threshold and shows the unseen branches' do
      sandbox.fake_script('bin/visual-coverage', "echo 'Markup branches : 97.5%'; echo 'unseen: meal.tsx:12'; " \
                                                 "echo 'other line'; exit 1")

      result = run_check

      expect(step_output(result.output, 'Screen states'))
        .to eq("==> Screen states\n    ✗ Below the threshold, or the run failed\nunseen: meal.tsx:12\n\n")
      expect(summary_line(result.output, 'Screen states')).to eq('✗  Screen states        97.5%')
    end
  end

  describe 'dependency freshness' do
    it 'reports outdated gems and packages as information, not a failure' do
      result = run_check(
        bundle: { 'outdated' => reply("Fetching gem metadata\n\nGem  Current  Latest\nrack 3.0 3.1\nrails 8.0 8.1\n",
                                      status: 1) },
        npm: { 'outdated' => reply("Package  Current  Wanted  Latest\naxios  1.14.0  1.14.1  1.14.1\n", status: 1) }
      )

      expect(result).to be_success, result.output
      expect(step_output(result.output, 'Ruby gems (outdated)'))
        .to eq("==> Ruby gems (outdated)\n    ⚠ 2 gem(s) have newer versions available\n      " \
               "rack 3.0 3.1\n      rails 8.0 8.1\n\n")
      expect(step_output(result.output, 'npm packages (outdated)'))
        .to include('⚠ 1 package(s) have newer versions available', '      axios  1.14.0  1.14.1  1.14.1')
      expect(summary_line(result.output, 'Gem freshness')).to eq('ℹ  Gem freshness        2 outdated')
      expect(summary_line(result.output, 'npm freshness')).to eq('ℹ  npm freshness        1 outdated')
      expect(result.output).to include('All checks passed.')
    end
  end

  describe 'the summary' do
    it 'counts the warnings next to the failures' do
      result = run_check(curl: curl_answers.merge('*/ruby/4.0.json' => reply('{"latest":"4.0.8"}')),
                         npm: { 'run lint' => reply("error\n", status: 1) })

      expect(result.exitstatus).to eq(1)
      expect(result.output).to include("  1 check(s) failed.\e[0m\n\e[0;33m  1 warning(s).")
      expect(result.output).to match(/Completed in 0m \d+s\n\z/)
    end
  end

  # grep exits 1 when it finds nothing and 2 when it cannot read a path,
  # even if it found matches in the other paths. If these two steps passed
  # on any exit that is not 0, then once a folder they read was moved or
  # renamed, they would pass whatever the code holds.
  describe 'a grep step when one of the paths it reads is gone' do
    it 'still fails on a TODO marker' do
      FileUtils.remove_entry(File.join(sandbox.root, 'app/controllers/api'))
      sandbox.write('app/services/settlement.rb', "# TODO: round later\n")

      result = run_check

      expect(summary_line(result.output, 'TODO markers')).to eq('✗  TODO markers         grep failed (exit 2)')
      expect(step_output(result.output, 'TODO markers'))
        .to include('grep could not read every path it checks (exit 2)', 'app/services/settlement.rb:1:# TODO')
    end

    it 'still fails on a date read from the app zone' do
      FileUtils.remove_entry(File.join(sandbox.root, 'db/seeds.rb'))
      sandbox.write('app/services/settlement.rb', "x = Date.today\n")

      result = run_check

      expect(summary_line(result.output, 'App-zone dates')).to eq('✗  App-zone dates       grep failed (exit 2)')
    end
  end

  # CI runs the steps that no other CI job runs this way (#225):
  #   bin/check sorbet rbi_fresh debride ...
  describe 'with step names' do
    it 'runs only those steps, in the order given, and sums up only them' do
      result = run_check('sorbet', 'todo_markers', 'debride')

      expect(result).to be_success, result.output
      plain = result.output.gsub(/\e\[[0-9;]*m/, '')
      expect(plain.scan(/^==> (.+)$/).flatten).to eq(['Sorbet', 'TODO markers', 'Debride'])
      summary = plain[plain.index("  Summary\n")..].lines.grep(/\A    [✓✗⚠ℹ] /).map(&:rstrip)
      expect(summary).to eq(['    ✓  Sorbet               no type errors',
                             '    ✓  TODO markers         none in money-path code',
                             '    ✓  Debride              no suspects'])
      expect(sandbox.call_lines('bundle').map { it.split[0..2].join(' ') })
        .to eq(['bundle exec srb', 'bundle exec rails', 'bundle exec debride'])
    end

    it 'fails when one of them fails' do
      result = run_check('sorbet', 'fasterer', bundle: { 'exec srb tc' => reply("Errors: 2\n", status: 1) })

      expect(result.exitstatus).to eq(1)
      expect(summary_line(result.output, 'Sorbet')).to eq('✗  Sorbet               2 type error(s)')
    end

    # A name that is not a step must not pass with nothing checked.
    it 'refuses a name that is not a step, before running any' do
      result = run_check('sorbet', 'srb')

      expect(result.exitstatus).to eq(2)
      expect(result.output).to eq("bin/check: no step named srb. Each name is a check_<name> function in bin/check.\n")
      expect(sandbox.calls).to eq([])
    end
  end
end
