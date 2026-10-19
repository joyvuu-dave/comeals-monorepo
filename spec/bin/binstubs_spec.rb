# frozen_string_literal: true

require 'rails_helper'

# The binstubs that Rails and Solid Queue generate and replace on upgrade:
# bin/rails, bin/rake and bin/jobs. These specs run them unchanged, with
# harmless arguments, so their lines are measured
# (spec/bin/preload/simplecov_child.rb) and a broken one fails here.
#
# bin/bundle, Bundler's binstub, is not run here. Its branches turn on
# BUNDLE_GEMFILE, BUNDLER_VERSION and the RubyGems version, and a process
# started from this suite already has Bundler set up from the suite's
# own environment: changing those variables there makes Bundler resolve
# again, and it can write a lockfile over the checkout's Gemfile.lock.
RSpec.describe 'the generated binstubs' do
  def run(*command)
    out, status = run_ruby_script(*command)
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
end
