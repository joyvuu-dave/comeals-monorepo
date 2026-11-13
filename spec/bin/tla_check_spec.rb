# frozen_string_literal: true

require 'rails_helper'

# bin/tla-check, bin/check's "TLA+ models" step (docs/models.md). Every
# outside command is a fake here: the download, the checksum, the lock,
# and Java running TLC.
RSpec.describe 'bin/tla-check', bash_coverage: BashCoverage.new('spec/bin/tla_check_spec.rb') do
  include_context 'with a script sandbox'

  let(:script) { sandbox.link('bin/tla-check') }
  let(:cache) { File.join(sandbox.root, 'cache') }
  let(:jar) { File.join(cache, 'tla-1.7.4', 'tla2tools.jar') }
  let(:tlc_says) { 'TLC2 Version 2.19 of 08 August 2024 (rev: 5a47802)' }

  before do
    sandbox.write('models/Settle.tla', "---- MODULE Settle ----\n====\n")
    write_case('Settle.today', 'holds')
    write_case('Settle.no-trigger', 'violates SettledRowsStay')
    # The lock: runs the command it was given. set -x turns the trace
    # back on, which the fake turned off, so the second run of the
    # script is measured too.
    sandbox.fake('python3', 'shift 3; set -x; exec "$@"')
    sandbox.fake('curl', ': > "$3"')
    sandbox.fake('shasum')
    sandbox.fake('java', java_body)
  end

  def write_case(name, expect)
    sandbox.write("models/cases/#{name}.cfg", "\\* expect: #{expect}\nSPECIFICATION Spec\n")
  end

  # What TLC prints when every invariant holds, and when one fails.
  def holds(states = '1,843')
    "#{tlc_says}\nModel checking completed. No error has been found.\n" \
      "4,288 states generated, #{states} distinct states found, 0 states left on queue.\n"
  end

  def violates(invariant)
    "#{tlc_says}\nError: Invariant #{invariant} is violated.\n" \
      "136 states generated, 75 distinct states found, 0 states left on queue.\n"
  end

  # A Java that answers -version, and runs TLC: each key is a case.
  def java_body(cases = { 'Settle.today' => [holds, 0], 'Settle.no-trigger' => [violates('SettledRowsStay'), 12] })
    tlc = cases.to_h do |name, (out, status)|
      ["*-config cases/#{name}.cfg *", "#{sandbox.says(out)}; exit #{status}"]
    end
    sandbox.answers({ '-version' => 'exit 0' }.merge(tlc))
  end

  # The output, with how long each case took written as N: a case can
  # take a second when the machine is busy.
  def check(*names, env: {})
    result = sandbox.run(script, *names, env: { 'COMEALS_CACHE' => cache }.merge(env))
    result.output.gsub!(/\b\d+ s\)/, 'N s)')
    result
  end

  def install
    sandbox.write('cache/tla-1.7.4/tla2tools.jar', 'jar')
  end

  it 'downloads and checks the pinned jar on the first run, then runs every case' do
    result = check

    expect(result).to be_success, result.output
    expect(result.output).to eq("Downloading tla2tools.jar 1.7.4 into #{File.dirname(jar)}\n" \
                                "ok    Settle.no-trigger: violates SettledRowsStay (75 distinct states, N s)\n" \
                                "ok    Settle.today: holds (1,843 distinct states, N s)\n" \
                                "2 cases gave the result they expect.\n")
    expect(sandbox.call_lines('curl'))
      .to eq(["curl -sSfL -o #{jar}.partial https://github.com/tlaplus/tlaplus/releases/download/v1.7.4/tla2tools.jar"])
    expect(sandbox.calls_to('python3').first.args.drop(2))
      .to eq([File.join(cache, 'tla.lock'), script, '--install-under-lock'])
    expect(File).to exist(jar)
    expect(File).not_to exist("#{jar}.partial")
  end

  it 'checks the jar against its pinned SHA-256' do
    sandbox.fake('shasum', 'cat > "$SANDBOX_DIR/shasum.in"')

    check

    expect(File.read(File.join(sandbox.dir, 'shasum.in')))
      .to eq("936a262061c914694dfd669a543be24573c45d5aa0ff20a8b96b23d01e050e88  #{jar}.partial\n")
  end

  it 'keeps no jar and runs nothing when the SHA-256 is not the pinned one' do
    sandbox.fake('shasum', 'exit 1')

    result = check

    expect(result.exitstatus).to eq(1)
    expect(result.output)
      .to end_with("bin/tla-check: tla2tools.jar does not have the pinned SHA-256. It was not kept.\n")
    expect(File).not_to exist(jar)
    expect(sandbox.call_lines('java').grep(/TLC/)).to be_empty
  end

  it 'downloads nothing when an earlier run kept the jar' do
    install

    result = check

    expect(result).to be_success, result.output
    expect(sandbox.calls_to('curl')).to be_empty
  end

  it 'runs TLC on each case from the models folder, with the case as its config' do
    install

    check('Settle.today')

    call = sandbox.calls_to('java').find { |c| c.args.include?('tlc2.TLC') }
    expect(call.pwd).to eq(File.join(sandbox.root, 'models'))
    expect(call.args.values_at(0, 1, 2, 3, 4,
                               5)).to eq(['-XX:+UseParallelGC', '-cp', jar, 'tlc2.TLC', '-workers', 'auto'])
    expect(call.args[6]).to eq('-metadir')
    expect(call.args[7]).to end_with('/Settle.today')
    expect(call.args.drop(8)).to eq(['-config', 'cases/Settle.today.cfg', 'Settle.tla'])
  end

  it 'runs only the cases it is given' do
    install

    result = check('Settle.today')

    expect(result).to be_success, result.output
    expect(result.output).to eq("ok    Settle.today: holds (1,843 distinct states, N s)\n" \
                                "1 cases gave the result they expect.\n")
  end

  it 'refuses a case that does not exist' do
    install

    result = check('Settle.nothing')

    expect(result.exitstatus).to eq(1)
    expect(result.output).to eq("bin/tla-check: there is no models/cases/Settle.nothing.cfg.\n")
  end

  it 'keeps the cache in ~/.cache/comeals when COMEALS_CACHE is not set' do
    home = File.join(sandbox.root, 'home')

    result = sandbox.run(script, env: { 'HOME' => home })

    expect(result).to be_success, result.output
    expect(sandbox.call_lines('curl').first).to include("-o #{home}/.cache/comeals/tla-1.7.4/tla2tools.jar.partial ")
  end

  describe 'which Java it runs' do
    before { install }

    it 'runs the Java that JAVA names' do
      sandbox.fake_script('jdk/bin/java', java_body)

      result = check(env: { 'JAVA' => File.join(sandbox.root, 'jdk/bin/java') })

      expect(result).to be_success, result.output
      expect(sandbox.calls_to('java')).to be_empty
    end

    it 'stops when the Java that JAVA names does not run' do
      result = check(env: { 'JAVA' => '/nowhere/java' })

      expect(result.exitstatus).to eq(1)
      expect(result.output).to eq("bin/tla-check: JAVA=/nowhere/java does not run.\n")
    end

    it "runs Homebrew's openjdk@21 when java on the PATH does not run" do
      sandbox.fake('java', 'exit 1')
      sandbox.fake_script('brew/opt/openjdk@21/bin/java', java_body)

      result = check(env: { 'HOMEBREW_PREFIX' => File.join(sandbox.root, 'brew') })

      expect(result).to be_success, result.output
      expect(sandbox.call_lines('java')).to eq(['java -version'])
    end

    it 'stops and says how to install one when there is no Java' do
      sandbox.fake('java', 'exit 1')

      result = check(env: { 'HOMEBREW_PREFIX' => File.join(sandbox.root, 'brew') })

      expect(result.exitstatus).to eq(1)
      expect(result.output)
        .to eq("bin/tla-check: no Java found. Install one (brew install openjdk@21) or set JAVA.\n")
    end
  end

  describe 'when a case does not give the result it expects' do
    before { install }

    def failing(java_cases)
      sandbox.fake('java', java_body(java_cases))
      check
    end

    it 'fails a case that must hold when TLC finds a state that breaks an invariant' do
      result = failing('Settle.today' => [violates('SettledOnce'), 12],
                       'Settle.no-trigger' => [violates('SettledRowsStay'), 12])

      expect(result.exitstatus).to eq(1)
      expect(result.output).to include('FAIL  Settle.today (N s): expected every invariant to hold, ' \
                                       "but: Error: Invariant SettledOnce is violated.\n")
      expect(result.output).to end_with("bin/tla-check: not every case gave the result it expects:\n" \
                                        '- Settle.today: expected every invariant to hold, ' \
                                        "but: Error: Invariant SettledOnce is violated.\n")
    end

    it 'fails a case that must hold when TLC exits with an error and says nothing' do
      result = failing('Settle.today' => ["#{tlc_says}\n", 150],
                       'Settle.no-trigger' => [violates('SettledRowsStay'), 12])

      expect(result.output).to include('- Settle.today: expected every invariant to hold, but: TLC exited with 150')
    end

    it 'fails a case that must fail when every invariant holds' do
      result = failing('Settle.today' => [holds, 0], 'Settle.no-trigger' => [holds, 0])

      expect(result.exitstatus).to eq(1)
      expect(result.output).to include('- Settle.no-trigger: expected SettledRowsStay to fail, ' \
                                       'but: Model checking completed. No error has been found.')
    end

    it 'fails a case that must fail when another invariant fails instead' do
      result = failing('Settle.today' => [holds, 0], 'Settle.no-trigger' => [violates('SettledOnce'), 12])

      expect(result.output).to include('- Settle.no-trigger: expected SettledRowsStay to fail, ' \
                                       'but: Error: Invariant SettledOnce is violated.')
    end

    it 'fails a case that must fail when TLC stops with nothing to say' do
      result = failing('Settle.today' => [holds, 0], 'Settle.no-trigger' => ["#{tlc_says}\n", 75])

      expect(result.output).to include('- Settle.no-trigger: expected SettledRowsStay to fail, but: TLC exited with 75')
    end

    it 'fails a run by another TLC' do
      result = failing('Settle.today' => ["TLC2 Version 2.18\n#{holds}", 0],
                       'Settle.no-trigger' => [violates('SettledRowsStay'), 12])

      expect(result.output).to include("- Settle.today: TLC's first line is not \"#{tlc_says}\"")
    end

    it 'shows a question mark when TLC did not say how many states it found' do
      result = failing('Settle.today' => ["#{tlc_says}\nModel checking completed. No error has been found.\n", 0],
                       'Settle.no-trigger' => [violates('SettledRowsStay'), 12])

      expect(result).to be_success, result.output
      expect(result.output).to include("ok    Settle.today: holds (? distinct states, N s)\n")
    end
  end

  describe 'the case files' do
    before { install }

    it 'fails a case whose first line does not say what to expect' do
      sandbox.write('models/cases/Settle.today.cfg', "SPECIFICATION Spec\n")

      result = check

      expect(result.exitstatus).to eq(1)
      expect(result.output).to include("- Settle.today: the first line must be '\\* expect: holds' or " \
                                       "'\\* expect: violates <Invariant>'")
    end

    it 'fails a case for a model that is not there' do
      write_case('Gone.today', 'holds')

      result = check

      expect(result.output).to include('- Gone.today: there is no models/Gone.tla')
    end

    it 'fails a model that has no case' do
      sandbox.write('models/Lonely.tla', "---- MODULE Lonely ----\n====\n")

      result = check

      expect(result.exitstatus).to eq(1)
      expect(result.output).to include('- models/Lonely.tla has no case in models/cases/')
    end

    it 'does not look for models without cases when it runs only some cases' do
      sandbox.write('models/Lonely.tla', "---- MODULE Lonely ----\n====\n")

      expect(check('Settle.today')).to be_success
    end
  end
end
