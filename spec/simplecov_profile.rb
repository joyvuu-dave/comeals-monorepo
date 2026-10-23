# frozen_string_literal: true

# What the Ruby coverage counts, in one place for the two places that use
# it: spec/spec_helper.rb, when RSpec runs, and bin/coverage-collate, which
# joins the results of the CI parts and checks the minimum for the whole.
# Loading it only defines the profile; nothing starts measuring.

require 'simplecov'

# The newest migration production has run, from
# db/production_schema_version.txt (its comment says when and how to
# update it). Every migration in db/migrate/ is newer, so production has
# not run it, and this suite must run all of its lines and branches
# before the deploy that runs it.
production_versions = File.readlines(File.expand_path('../db/production_schema_version.txt', __dir__), chomp: true)
                          .reject { |line| line.start_with?('#') || line.strip.empty? }
if production_versions.size != 1
  raise "db/production_schema_version.txt must hold one version, not #{production_versions}"
end

PRODUCTION_SCHEMA_VERSION = Integer(production_versions.first, 10)

# The minimum for a run of the whole suite.
SIMPLECOV_MINIMUM = { line: 100, branch: 100 }.freeze

SimpleCov.profiles.define 'comeals' do
  load_profile 'rails'
  enable_coverage :branch
  # The rails profile leaves out all of config/ and db/. This suite counts
  # config/initializers/ and the migrations, which production has not run
  # (the ones it ran are deleted), so those two rules come out and
  # narrower ones go in below.
  remove_filter(%r{\Aconfig/})
  remove_filter(%r{\Adb/})
  skip '/spec/'
  skip '/vendor/'
  skip %r{\Aconfig/(?!initializers/)}
  skip %r{\Adb/(?!migrate/)}

  # The files this suite answers for. A file here that no spec loads is
  # counted at 0%, not left out: a spec loads a migration only when it
  # tests that migration, so a new migration with no spec would otherwise
  # be missing from the report. bin/lib holds Ruby that bin/rails runner
  # runs (the staging smoke seed).
  cover 'app/**/*.rb', 'lib/**/*.{rb,rake}', 'config/initializers/*.rb', 'db/migrate/*.rb', 'bin/lib/**/*.rb'
  # The Ruby scripts in bin/. Each runs in a process of its own under
  # spec/bin, and its counts are added to this run's result
  # (spec/child_coverage.rb). Named here, a script whose specs are gone is
  # counted at 0% instead of left out.
  cover 'bin/{mutant-report,tapioca,setup,rails,rake,jobs,bundle}'
  # Loads the annotate_rb gem's own tasks, in development only. The gem is
  # in the development group of the Gemfile, so the test bundle cannot
  # load it, and no spec can run the file's one branch.
  skip '/lib/tasks/annotate_rb.rake'
end
