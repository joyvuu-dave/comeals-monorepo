# frozen_string_literal: true

# The stand-in for the tapioca gem's command (see fake_tapioca.rb). It runs
# in a process of its own, and printing is its job.
# rubocop:disable RSpec/Output
puts "tapioca #{ARGV.join(' ')}"
puts "DATABASE_URL=#{ENV.fetch('DATABASE_URL', '(not set)')}"
# rubocop:enable RSpec/Output
