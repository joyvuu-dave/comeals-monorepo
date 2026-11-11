# frozen_string_literal: true

require 'rails_helper'

# bin/mutant-spec-subjects names the methods whose examples changed, for
# the mutant-changed job in CI. Each example builds a small repository.
RSpec.describe 'bin/mutant-spec-subjects' do
  let(:script) { Rails.root.join('bin/mutant-spec-subjects').to_s }
  let(:dir) { Dir.mktmpdir }
  let(:subjects) do
    %w[Foo#a Foo.b Foo::Inner#c Food#d Bar#e Bar#f Baz#g Money#h Sig#i]
  end

  after { FileUtils.remove_entry(dir) }

  def write(path, text)
    full = File.join(dir, path)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, text)
  end

  def git(*)
    out, status = Open3.capture2e('git', '-c', 'user.name=t', '-c', 'user.email=t@example.com',
                                  '-c', 'commit.gpgsign=false', *, chdir: dir)
    raise out unless status.success?

    out
  end

  def run_script(base = 'HEAD')
    File.write(File.join(dir, 'subjects.txt'), "#{subjects.join("\n")}\nnot a subject\n")
    run_ruby_script(script, base, 'subjects.txt', chdir: dir)
  end

  before do
    write('spec/support/mutant/specs.rb', <<~RUBY)
      MUTANT_SPECS = { 'spec/models/money_spec.rb' => %w[Money Bar#f] }.freeze
      MUTANT_SIG_CHECK_SPECS = %w[spec/models/sig_spec.rb].freeze
    RUBY
    write('spec/models/foo_spec.rb', "RSpec.describe Foo do\nend\n")
    write('spec/models/bar_spec.rb', "RSpec.describe 'Bar#e does a thing' do\nend\n")
    write('spec/models/baz_spec.rb', "RSpec.describe Baz do\nend\n")
    write('spec/models/money_spec.rb', "RSpec.describe 'money' do\nend\n")
    write('spec/models/sig_spec.rb', "RSpec.describe Sig do\nend\n")
    write('spec/models/words_spec.rb', "RSpec.describe 'some words' do\nend\n")
    git('init', '-q')
    git('add', '.')
    git('commit', '-q', '-m', 'base')
  end

  it 'names nothing when no spec changed' do
    out, status = run_script

    expect(status.exitstatus).to eq(0), out
    expect(out).to eq('')
  end

  it "names a changed spec's class, with the classes inside it, but not a class that only starts the same" do
    write('spec/models/foo_spec.rb', "RSpec.describe Foo do\n  it('x') {}\nend\n")

    out, = run_script

    expect(out.lines(chomp: true)).to eq(%w[Foo#a Foo.b Foo::Inner#c])
  end

  it 'names only the method a describe names' do
    write('spec/models/bar_spec.rb', "RSpec.describe 'Bar#e does a thing' do\n  it('x') {}\nend\n")

    out, = run_script

    expect(out.lines(chomp: true)).to eq(%w[Bar#e])
  end

  it 'reads a deleted spec as it was at the base commit' do
    File.delete(File.join(dir, 'spec/models/baz_spec.rb'))

    out, = run_script

    expect(out.lines(chomp: true)).to eq(%w[Baz#g])
  end

  it "uses a file's row in spec/support/mutant/specs.rb, and names nothing for a file mutant never runs" do
    write('spec/models/money_spec.rb', "RSpec.describe 'money' do\n  it('x') {}\nend\n")
    write('spec/models/sig_spec.rb', "RSpec.describe Sig do\n  it('x') {}\nend\n")
    write('spec/models/words_spec.rb', "RSpec.describe 'some words' do\n  it('x') {}\nend\n")

    out, = run_script

    expect(out.lines(chomp: true)).to eq(%w[Bar#f Money#h])
  end

  it 'leaves out a new spec, which can only kill more' do
    write('spec/models/new_spec.rb', "RSpec.describe Foo do\nend\n")
    git('add', '.')

    out, = run_script

    expect(out).to eq('')
  end

  it 'fails on a base git does not know' do
    out, status = run_script('no-such-commit')

    expect(status.exitstatus).to eq(1)
    expect(out).to include('git diff')
  end

  it 'refuses the wrong number of arguments' do
    out, status = run_ruby_script(script, 'HEAD', chdir: dir)

    expect(status.exitstatus).to eq(2)
    expect(out).to include('Usage: bin/mutant-spec-subjects')
  end
end
