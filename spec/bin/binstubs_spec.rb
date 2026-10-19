# frozen_string_literal: true

require 'rails_helper'

# The binstubs that Rails, Bundler and Solid Queue generate and replace on
# upgrade: bin/rails, bin/rake, bin/jobs and bin/bundle. These specs run
# them unchanged, with harmless arguments, so their lines are measured
# (spec/bin/preload/simplecov_child.rb) and a broken one fails here.
RSpec.describe 'the generated binstubs' do
  def run(*command, **)
    out, status = run_ruby_script(*command, **)
    [out, status.exitstatus]
  end

  def bin(name) = Rails.root.join('bin', name).to_s

  it 'bin/rails runs the Rails command line' do
    expect(run(bin('rails'), '--version')).to eq(["Rails #{Rails.version}\n", 0])
  end

  it 'bin/rake runs Rake' do
    expect(run(bin('rake'), '--version')).to eq(["rake, version #{Rake::VERSION}\n", 0])
  end

  it 'bin/jobs boots the app and runs the Solid Queue command line' do
    out, status = run(bin('jobs'), '--help')

    expect(status).to eq(0)
    expect(out).to include('jobs start', 'Starts Solid Queue supervisor')
  end

  # bin/bundle's branches turn on BUNDLE_GEMFILE, BUNDLER_VERSION and the
  # RubyGems version. A process that has Bundler set up from this suite
  # would resolve the Gemfile again when those change, and could write a
  # lockfile over the checkout's Gemfile.lock. So these runs are outside
  # Bundler, Bundler's own command is a fake
  # (spec/bin/preload/fake_bundler.rb), and each example checks that
  # Gemfile.lock did not change.
  describe 'bin/bundle' do
    let(:dir) { Dir.mktmpdir }
    let(:lockfile) { Rails.root.join('Gemfile.lock') }
    let(:locked) { "GEM\n  specs:\n\nBUNDLED WITH\n   #{Bundler::VERSION}\n" }

    around do |example|
      before = [File.read(lockfile), File.mtime(lockfile)]
      example.run
      raise 'bin/bundle changed Gemfile.lock' unless [File.read(lockfile), File.mtime(lockfile)] == before
    ensure
      FileUtils.remove_entry(dir)
    end

    def bundle(*, env: {})
      run(bin('bundle'), *, env: env, preload: %w[fake_bundler], bundled: false)
    end

    # A Gemfile of its own, with the given lockfile text.
    def gemfile(lock, name: 'Gemfile')
      path = File.join(dir, name)
      File.write(path, "source 'https://rubygems.org'\n")
      File.write("#{path}.lock", lock) if lock
      path
    end

    def handed_over(args, gemfile = Rails.root.join('Gemfile').to_s)
      ["bundle #{args}\nBUNDLE_GEMFILE=#{gemfile}\n", 0]
    end

    it "activates the Bundler of the app's lockfile and hands over to Bundler with its Gemfile" do
      expect(bundle('--version')).to eq(handed_over('--version'))
    end

    it 'treats an empty BUNDLE_GEMFILE as not set when it looks for the lockfile' do
      expect(bundle('--version', env: { 'BUNDLE_GEMFILE' => '' })).to eq(handed_over('--version', ''))
    end

    it 'takes the version from BUNDLER_VERSION' do
      expect(bundle('--version', env: { 'BUNDLER_VERSION' => Bundler::VERSION })).to eq(handed_over('--version'))
    end

    it 'takes the version from `bundle update --bundler VERSION` and `--bundler=VERSION`' do
      expect(bundle('update', '--bundler', Bundler::VERSION))
        .to eq(handed_over("update --bundler #{Bundler::VERSION}"))
      expect(bundle('update', "--bundler=#{Bundler::VERSION}"))
        .to eq(handed_over("update --bundler=#{Bundler::VERSION}"))
    end

    it 'asks for any version when the lockfile names none, or there is no lockfile' do
      without = gemfile("GEM\n  specs:\n")
      expect(bundle('--version', env: { 'BUNDLE_GEMFILE' => without })).to eq(handed_over('--version', without))

      gems_rb = gemfile(nil, name: 'gems.rb')
      expect(bundle('--version', env: { 'BUNDLE_GEMFILE' => gems_rb })).to eq(handed_over('--version', gems_rb))
    end

    it 'stops with exit 42 and the command to run when that Bundler cannot be activated' do
      out, status = bundle('--version', env: { 'BUNDLE_GEMFILE' => gemfile(locked.sub(Bundler::VERSION, '0.0.1')) })

      expect(status).to eq(42)
      expect(out).to include('Activating bundler (~> 0.0) failed:', "gem install bundler -v '~> 0.0'")
    end

    it 'goes on when `gem "bundler"` fails but the Bundler it loads is the right one' do
      expect(bundle('--version', env: { 'FAKE_BUNDLER_GEM_ERROR' => '1' })).to eq(handed_over('--version'))
    end

    describe 'with a RubyGems older than 2.7' do
      it 'asks for the locked version' do
        own = gemfile(locked)

        out = bundle('--version', env: { 'FAKE_RUBYGEMS_VERSION' => '2.6.0', 'BUNDLE_GEMFILE' => own })

        expect(out).to eq(handed_over('--version', own))
      end

      # The old RubyGems asked for ".a" to be added by hand; today's
      # approximate_recommendation adds one too, so the fake shows both.
      it 'asks for a prerelease of the locked version when that is one' do
        prerelease = gemfile(locked.sub(Bundler::VERSION, '99.1.0.pre'))

        out, status = bundle('--version', env: { 'FAKE_RUBYGEMS_VERSION' => '2.6.0', 'BUNDLE_GEMFILE' => prerelease })

        expect(status).to eq(42)
        expect(out).to include('Activating bundler (~> 99.1.a.a) failed:')
      end
    end

    it 'only activates Bundler when another script loads it' do
      out = run('ruby', '-e', 'load ARGV.shift; puts "loaded"', bin('bundle'), 'update',
                preload: %w[fake_bundler], bundled: false)

      expect(out).to eq(["loaded\n", 0])
    end
  end
end
