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
# still reloads after something wipes rake state (the billing snapshot spec
# calls Rake::Task.clear to guarantee its own single-action invariant).
module RakeTasks
  SENTINEL_TASK = 'billing:recalculate'

  def self.ensure_loaded
    Rails.application.load_tasks unless Rake::Task.task_defined?(SENTINEL_TASK)
  end
end
