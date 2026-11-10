# frozen_string_literal: true

require 'rails_helper'

# bin/dafny-verify, bin/check's "Dafny" step (docs/proofs.md). Every
# outside command is a fake here: the download, the checksum, the unzip,
# the lock, and the Dafny and Z3 the zip holds.
RSpec.describe 'bin/dafny-verify', bash_coverage: BashCoverage.new('spec/bin/dafny_verify_spec.rb') do
  include_context 'with a script sandbox'

  let(:script) { sandbox.link('bin/dafny-verify') }
  let(:cache) { File.join(sandbox.root, 'cache') }
  let(:installed) { File.join(cache, 'dafny-4.11.0') }
  let(:dafny) { 'cache/dafny-4.11.0/dafny/dafny' }
  let(:z3) { 'cache/dafny-4.11.0/dafny/z3/bin/z3-4.14.1' }
  let(:zip) { File.join(cache, 'dafny-4.11.0-arm64-macos-13.zip') }
  let(:passed) { "\nDafny program verifier finished with 4 verified, 0 errors\n" }
  let(:fresh) { File.join(sandbox.root, 'fresh') }

  before do
    sandbox.write('proofs/Sums.dfy', "module Sums {}\n")
    sandbox.fake('uname', sandbox.answers({ '-s' => 'echo Darwin', '-m' => 'echo arm64' }))
    # The lock: runs the command it was given. set -x turns the trace
    # back on, which the fake turned off, so the second run of the
    # script is measured too.
    sandbox.fake('python3', 'shift 3; set -x; exec "$@"')
    sandbox.fake('curl', ': > "$3"')
    sandbox.fake('shasum')
    # The zip holds a dafny and a z3; both are fakes, linked into the
    # folder unzip was told to fill.
    sandbox.fake('unzip', <<~BASH)
      mkdir -p "$5/dafny/z3/bin"
      ln -s #{sandbox.dispatcher.shellescape} "$5/dafny/dafny"
      ln -s #{sandbox.dispatcher.shellescape} "$5/dafny/z3/bin/z3-4.14.1"
    BASH
    fake_tool(z3, 'echo "Z3 version 4.14.1 - 64 bit"')
    fake_tool(dafny, dafny_body)
    # The folder for the Python made to compare, and the comparison.
    sandbox.fake('mktemp', 'mkdir -p "$SANDBOX_ROOT/fresh"; echo "$SANDBOX_ROOT/fresh"')
    sandbox.fake('diff')
  end

  # A Dafny that proves everything, makes Python, and writes `csv` as the
  # results of measure-complexity.
  def dafny_body(verify: sandbox.says(passed), translate: 'exit 0', csv: seeds_csv(2), measure: 'exit 0')
    sandbox.write('measured.csv', csv)
    sandbox.answers({ 'verify *' => verify,
                      'translate *' => translate,
                      'measure-complexity *' => "#{copy_csv}; #{measure}" })
  end

  # Copies measured.csv to the file named by --log-format csv;LogFileName=.
  def copy_csv
    'for arg in "$@"; do case "$arg" in "csv;LogFileName="*) ' \
      'cp "$SANDBOX_ROOT/measured.csv" "${arg#csv;LogFileName=}" ;; esac; done'
  end

  def seeds_csv(seeds, outcome: 'Passed')
    rows = (1..seeds).flat_map do |seed|
      ["Sums.Sum (correctness),#{outcome},00:00:00.01,100,#{seed}",
       "Sums.Lemma (correctness),Passed,00:00:00.01,100,#{seed}"]
    end
    header = 'TestResult.DisplayName,TestResult.Outcome,TestResult.Duration,TestResult.ResourceCount,RandomSeed'
    [header, *rows].map { "#{it}\n" }.join
  end

  def translate_call(output) = "#{dafny} translate py --no-verify --include-runtime --output #{output} proofs/Sums.dfy"
  def diff_call = "diff -r -x __pycache__ proofs/generated-py #{fresh}/generated-py"
  def fresh_line = "proofs/generated-py is what Dafny makes from proofs/*.dfy.\n"

  # Writes the body of a tool that the zip holds. Makes the tool only if
  # #install made it already: otherwise unzip makes it.
  def fake_tool(path, body)
    there = File.symlink?(File.join(sandbox.root, path))
    made = sandbox.fake_script(path, body)
    return if there

    File.delete(made)
    FileUtils.remove_dir(File.join(sandbox.root, path[%r{\A.*?/dafny-4\.11\.0}]))
  end

  # Puts the tools where an earlier run left them.
  def install
    [dafny, z3].each do |path|
      FileUtils.mkdir_p(File.dirname(File.join(sandbox.root, path)))
      File.symlink(sandbox.dispatcher, File.join(sandbox.root, path))
    end
  end

  def verify(env: {}) = sandbox.run(script, env: { 'COMEALS_CACHE' => cache }.merge(env))

  def verify_call = "#{dafny} verify --solver-path #{File.join(sandbox.root, z3)} --cores 2 proofs/Sums.dfy"

  it 'downloads, checks and unpacks the pinned zip on the first run, then proves every file' do
    result = verify

    expect(result).to be_success, result.output
    expect(result.output).to eq("Downloading dafny-4.11.0-arm64-macos-13.zip into #{cache}\n#{passed}#{fresh_line}")
    expect(sandbox.call_lines.grep_v(/\Auname /)).to eq([
                                                          sandbox.call_lines('python3').first,
                                                          'curl -sSfL -o ' \
                                                          "#{zip} https://github.com/dafny-lang/dafny/releases/download/v4.11.0/dafny-4.11.0-arm64-macos-13.zip",
                                                          'shasum -a 256 -c -',
                                                          "unzip -q -o #{zip} -d #{installed}.partial",
                                                          "rm -f #{zip}",
                                                          "#{z3} --version",
                                                          verify_call,
                                                          'mktemp -d',
                                                          translate_call("#{fresh}/generated"),
                                                          diff_call,
                                                          "rm -r #{fresh}"
                                                        ])
    expect(sandbox.calls_to('python3').first.args.drop(2))
      .to eq([File.join(cache, 'dafny.lock'), script, '--install-under-lock'])
    expect(File).to exist(File.join(sandbox.root, dafny))
    expect(File).not_to exist("#{installed}.partial")
    expect(File).not_to exist(zip)
  end

  it 'checks the zip against its pinned SHA-256' do
    sandbox.fake('shasum', 'cat > "$SANDBOX_DIR/shasum.in"')

    verify

    expect(File.read(File.join(sandbox.dir, 'shasum.in')))
      .to eq("c90c75e7d5db9c6ccbb7127840dfe43f0ac938b039a7ebed146d8ead383a572f  #{zip}\n")
  end

  it 'uses the Linux zip and its SHA-256 on Linux' do
    sandbox.fake('uname', sandbox.answers({ '-s' => 'echo Linux', '-m' => 'echo x86_64' }))

    result = verify

    expect(result).to be_success, result.output
    expect(sandbox.call_lines('curl').first).to end_with('/v4.11.0/dafny-4.11.0-x64-ubuntu-22.04.zip')
  end

  it 'downloads nothing when an earlier run unpacked the zip' do
    install

    result = verify

    expect(result).to be_success, result.output
    expect(result.output).to eq("#{passed}#{fresh_line}")
    expect(sandbox.calls_to('curl')).to be_empty
    expect(sandbox.call_lines).to include(verify_call)
  end

  it 'keeps the cache in ~/.cache/comeals when COMEALS_CACHE is not set' do
    home = File.join(sandbox.root, 'home')
    fake_tool('home/.cache/comeals/dafny-4.11.0/dafny/z3/bin/z3-4.14.1', 'echo "Z3 version 4.14.1 - 64 bit"')
    fake_tool('home/.cache/comeals/dafny-4.11.0/dafny/dafny', sandbox.says(passed))

    result = sandbox.run(script, env: { 'HOME' => home })

    expect(result).to be_success, result.output
    expect(sandbox.call_lines('unzip').first).to end_with("-d #{home}/.cache/comeals/dafny-4.11.0.partial")
  end

  it 'stops when the folder is there but has no dafny in it, rather than unpack into it' do
    FileUtils.mkdir_p(installed)

    result = verify

    expect(result.exitstatus).to eq(1)
    expect(result.output).to eq("bin/dafny-verify: #{installed} is there but has no dafny in it. " \
                                "Delete that folder and run this again.\n")
    expect(sandbox.calls_to('curl')).to be_empty
  end

  it 'unpacks nothing and deletes the zip when the SHA-256 is not the pinned one' do
    sandbox.fake('shasum', 'exit 1')

    result = verify

    expect(result.exitstatus).to eq(1)
    expect(result.output).to include('dafny-4.11.0-arm64-macos-13.zip does not have the pinned SHA-256. ' \
                                     'Nothing was unpacked.')
    expect(sandbox.calls_to('unzip')).to be_empty
    expect(sandbox.calls_to(dafny)).to be_empty
    expect(File).not_to exist(zip)
  end

  it 'stops on a machine with no pinned zip' do
    sandbox.fake('uname', sandbox.answers({ '-s' => 'echo Linux', '-m' => 'echo aarch64' }))

    result = verify

    expect(result.exitstatus).to eq(1)
    expect(result.output).to include('no Dafny zip is pinned for Linux aarch64')
    expect(sandbox.calls_to('curl')).to be_empty
  end

  {
    'assume' => "  assume x > 0;\n",
    '{:axiom}' => "lemma {:axiom} Free()\n",
    '{ :axiom }, with spaces' => "lemma { :axiom } Free()\n",
    '{:verify false}' => "lemma {:verify  false} Skipped() {}\n"
  }.each do |word, line|
    it "refuses a proof that uses #{word}, before running Dafny" do
      sandbox.write('proofs/Free.dfy', line)

      result = verify

      expect(result.exitstatus).to eq(1)
      expect(result.output).to eq("bin/dafny-verify: these lines take a claim without proving it:\n" \
                                  "proofs/Free.dfy:1:#{line}")
      expect(sandbox.calls_to(dafny)).to be_empty
    end
  end

  it 'does not mistake a word that only contains "assume" for it' do
    sandbox.write('proofs/Sums.dfy', "// the caller assumed nothing\nmodule Sums {}\n")

    expect(verify).to be_success
  end

  it 'refuses a Z3 that is not the pinned version' do
    install
    fake_tool(z3, 'echo "Z3 version 4.12.1 - 64 bit"')

    result = verify

    expect(result.exitstatus).to eq(1)
    expect(result.output).to eq("bin/dafny-verify: #{File.join(sandbox.root, z3)} says " \
                                "\"Z3 version 4.12.1 - 64 bit\", not Z3 version 4.14.1.\n")
    expect(sandbox.calls_to(dafny)).to be_empty
  end

  it 'fails when Dafny fails, and says why' do
    install
    fake_tool(dafny, "#{sandbox.says("Dafny program verifier finished with 4 verified, 1 error\n")}; exit 4")

    result = verify

    expect(result.exitstatus).to eq(1)
    expect(result.output).to eq("Dafny program verifier finished with 4 verified, 1 error\n\n" \
                                "bin/dafny-verify: this run does not count:\n" \
                                "- dafny exited with 4\n" \
                                '- the last line is not "Dafny program verifier finished with N verified, ' \
                                "0 errors\"\n")
  end

  it 'fails when Dafny skipped a proof but still exited with 0' do
    install
    fake_tool(dafny, sandbox.says("Sums.Sum: SKIPPED because of internal error\n#{passed}"))

    result = verify

    expect(result.exitstatus).to eq(1)
    expect(result.output).to end_with("bin/dafny-verify: this run does not count:\n" \
                                      '- a line says the prover failed or a proof was skipped: ' \
                                      "Sums.Sum: SKIPPED because of internal error\n")
  end

  it 'fails when the last line is not the summary' do
    install
    fake_tool(dafny, sandbox.says("#{passed}Compilation failed because warnings were found\n"))

    result = verify

    expect(result.exitstatus).to eq(1)
    expect(result.output).to end_with('- the last line is not "Dafny program verifier finished with N verified, ' \
                                      "0 errors\"\n")
  end

  it 'looks for those words only in the .dfy files, not in the Python made from them' do
    sandbox.write('proofs/generated-py/_dafny/__init__.py', "# This class assumes the source data is immutable\n")
    sandbox.write('proofs/generated-py/Free.py', "assume = 1\n")

    expect(verify).to be_success
  end

  it 'fails when proofs/generated-py is not what Dafny makes from the proofs, and says how to fix it' do
    install
    sandbox.fake('diff', 'echo "Only in proofs/generated-py: Old.py"; exit 1')

    result = verify

    expect(result.exitstatus).to eq(1)
    expect(result.output).to eq("#{passed}Only in proofs/generated-py: Old.py\n" \
                                "bin/dafny-verify: proofs/generated-py is not what Dafny makes from proofs/*.dfy.\n" \
                                "Run bin/dafny-verify --write-python and commit what it changes.\n")
    expect(sandbox.call_lines('rm')).to eq(["rm -r #{fresh}"])
  end

  it 'fails, with what Dafny said, when Dafny cannot make Python' do
    install
    fake_tool(dafny, dafny_body(translate: "#{sandbox.says("Error: cannot compile\n")}; exit 3"))

    result = verify

    expect(result.exitstatus).to eq(1)
    expect(result.output).to end_with("Error: cannot compile\n" \
                                      "bin/dafny-verify: Dafny could not make Python from proofs/.\n")
  end

  it 'makes proofs/generated-py again with --write-python, and proves nothing' do
    install

    result = sandbox.run(script, '--write-python', env: { 'COMEALS_CACHE' => cache })

    expect(result).to be_success, result.output
    expect(result.output).to eq("Wrote proofs/generated-py. Run bin/dafny-verify to check it, then commit it.\n")
    expect(sandbox.call_lines(dafny)).to eq([translate_call('proofs/generated')])
  end

  def seeds(count, env: {}) = sandbox.run(script, '--seeds', count, env: { 'COMEALS_CACHE' => cache }.merge(env))

  it 'checks every proof on N seeds with --seeds N' do
    install

    result = seeds('2')

    expect(result).to be_success, result.output
    expect(result.output).to eq("#{passed}#{fresh_line}Every proof passed on 2 seeds (4 runs).\n")
    expect(sandbox.call_lines(dafny).last)
      .to eq("#{dafny} measure-complexity --mutations 2 --random-seed 4242 " \
             "--solver-path #{File.join(sandbox.root, z3)} --cores 2 " \
             "--log-format csv;LogFileName=#{fresh}/seeds.csv proofs/Sums.dfy")
  end

  it 'fails when a proof fails on a seed, and names the proof and the seed' do
    install
    fake_tool(dafny, dafny_body(csv: seeds_csv(2, outcome: 'Failed'), measure: 'exit 1'))

    result = seeds('2')

    expect(result.exitstatus).to eq(1)
    expect(result.output).to end_with("bin/dafny-verify: not every proof passed on 2 seeds:\n" \
                                      "- dafny measure-complexity exited with 1\n" \
                                      "- Sums.Sum (correctness) on seed 1: Failed\n" \
                                      "Sums.Sum (correctness) on seed 2: Failed\n")
  end

  it 'fails when a proof did not run on every seed' do
    install
    fake_tool(dafny, dafny_body(csv: seeds_csv(3)))

    result = seeds('2')

    expect(result.exitstatus).to eq(1)
    expect(result.output).to include("Sums.Sum (correctness) ran 3 times\n")
    expect(result.output).to include("Sums.Lemma (correctness) ran 3 times\n")
  end

  it 'fails when no proof ran' do
    install
    fake_tool(dafny, dafny_body(csv: seeds_csv(0)))

    result = seeds('2')

    expect(result.exitstatus).to eq(1)
    expect(result.output).to end_with("- no proof ran\n")
  end

  it 'fails when measure-complexity wrote no results' do
    install
    fake_tool(dafny, sandbox.answers({ 'verify *' => sandbox.says(passed), 'measure-complexity *' => 'exit 2' }))

    result = seeds('2')

    expect(result.exitstatus).to eq(1)
    expect(result.output).to end_with("bin/dafny-verify: not every proof passed on 2 seeds:\n" \
                                      "- dafny measure-complexity exited with 2\n" \
                                      "- dafny measure-complexity wrote no results\n")
  end

  ['', '0', '20x', '-1'].each do |count|
    it "refuses --seeds #{count.inspect}" do
      result = seeds(count)

      expect(result.exitstatus).to eq(1)
      expect(result.output).to eq("bin/dafny-verify: --seeds takes a whole number above 0, like 20.\n")
      expect(sandbox.calls_to(dafny)).to be_empty
    end
  end

  it 'refuses an option it does not know' do
    result = sandbox.run(script, '--prove-harder', env: { 'COMEALS_CACHE' => cache })

    expect(result.exitstatus).to eq(1)
    expect(result.output).to eq("usage: bin/dafny-verify [--seeds N | --write-python]\n")
  end
end
