# frozen_string_literal: true

# The stand-in for Bundler's command (see fake_bundler.rb). It runs in a
# process of its own, and printing is its job.
# rubocop:disable RSpec/Output
puts "bundle #{ARGV.join(' ')}"
puts "BUNDLE_GEMFILE=#{ENV.fetch('BUNDLE_GEMFILE', '(not set)')}"
# rubocop:enable RSpec/Output
