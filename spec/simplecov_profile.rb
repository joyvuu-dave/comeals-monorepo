# frozen_string_literal: true

# What the Ruby coverage counts, in one place for the two places that use
# it: spec/spec_helper.rb, when RSpec runs, and bin/coverage-collate, which
# joins the results of the CI parts and checks the minimum for the whole.
# Loading it only defines the profile; nothing starts measuring.

require 'simplecov'

# The migrations production has run, from db/production_migrations.txt
# (its comment says when and how to update it), and the newest of them.
# Every migration after that one has not run there yet, so this suite must
# run all of its lines and branches before the deploy that runs it; the
# ones up to it already ran and are left out of the coverage count.
PRODUCTION_MIGRATIONS = File.readlines(File.expand_path('../db/production_migrations.txt', __dir__), chomp: true)
                            .reject { |line| line.start_with?('#') || line.strip.empty? }
                            .map { |line| Integer(line, 10) }
                            .freeze
PRODUCTION_SCHEMA_VERSION = PRODUCTION_MIGRATIONS.max

# The minimum for a run of the whole suite.
SIMPLECOV_MINIMUM = { line: 100, branch: 100 }.freeze

SimpleCov.profiles.define 'comeals' do
  load_profile 'rails'
  enable_coverage :branch
  # The rails profile leaves out all of config/ and db/. This suite counts
  # config/initializers/ and the migrations production has not run, so
  # those two rules come out and narrower ones go in below.
  remove_filter(%r{\Aconfig/})
  remove_filter(%r{\Adb/})
  skip '/spec/'
  skip '/vendor/'
  skip %r{\Aconfig/(?!initializers/)}
  skip %r{\Adb/(?!migrate/)}
  skip do |file|
    version = file.project_filename[%r{\Adb/migrate/(\d+)_}, 1]
    version && Integer(version, 10) <= PRODUCTION_SCHEMA_VERSION
  end

  # The files this suite answers for. A file here that no spec loads is
  # counted at 0%, not left out: a spec loads a migration only when it
  # tests that migration, so a new migration with no spec would otherwise
  # be missing from the report.
  cover 'app/**/*.rb', 'lib/**/*.{rb,rake}', 'config/initializers/*.rb', 'db/migrate/*.rb'
  # Loads the annotate_rb gem's own tasks, in development only. The gem is
  # in the development group of the Gemfile, so the test bundle cannot
  # load it, and no spec can run the file's one branch.
  skip '/lib/tasks/annotate_rb.rake'
end
