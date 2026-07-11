# frozen_string_literal: true

require 'rake'

# Loads the app's rake tasks exactly once per test process.
#
# Rails.application.load_tasks re-runs every task definition file each time
# it is called, and Rake appends the body as one more action on the already
# defined task — after two calls, one invoke runs the task body twice
# (issue #27). Task specs must call ensure_loaded instead of load_tasks.
#
# The guard checks a sentinel task instead of memoizing a flag so the helper
# would still recover if something wiped rake state. Nothing should: a
# re-load resets each .rake file's Ruby coverage counters, understating rake
# task coverage for the whole run (see rake_tasks_loading_spec.rb).
module RakeTasks
  SENTINEL_TASK = 'billing:recalculate'

  def self.ensure_loaded
    Rails.application.load_tasks unless Rake::Task.task_defined?(SENTINEL_TASK)
  end
end
