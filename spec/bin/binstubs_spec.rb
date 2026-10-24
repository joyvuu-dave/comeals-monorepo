# frozen_string_literal: true

require 'rails_helper'

# The binstubs that Rails and Solid Queue generate and replace on upgrade:
# bin/rails, bin/rake and bin/jobs. These specs run them unchanged, with
# harmless arguments, so their lines are measured
# (spec/bin/preload/child_coverage.rb) and a broken one fails here.
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

  # Heroku's Ruby buildpack warns about a bin/bundle binstub: its
  # `bundle clean` can remove the Bundler that bin/bundle asks for, and the
  # app then runs with Ruby's default Bundler (heroku-buildpack-ruby issue
  # 1690). Nothing here runs bin/bundle; every script runs `bundle`.
  # `bundle binstubs bundler` writes the file again.
  it 'has no bin/bundle' do
    expect(Rails.root.join('bin/bundle')).not_to exist
  end
end
