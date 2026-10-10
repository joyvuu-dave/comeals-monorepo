# frozen_string_literal: true

# Jobs go through Solid Queue, as in production, instead of the test
# adapter. A queued job is then a row in this database, written in the
# transaction that is open when it is queued, so a spec can see what a
# rollback does to it, and a refused INSERT reaches the caller the way
# Solid Queue raises it (SolidQueue::Job::EnqueueError). The test adapter
# keeps jobs in memory, where neither can happen.
#
# Nothing runs the jobs: there is no worker. Use it together with
# include_context 'with no test transaction', so the job rows really
# commit, and NonTransactionalCleanup removes them.
#
# Before and after hooks, not an around: the suite's own after hook
# (rails_helper.rb) sets flags on the test adapter, and an around would
# still hold Solid Queue's adapter when that hook runs.
RSpec.shared_context 'with Solid Queue as the job adapter' do
  test_adapter = nil

  before do
    test_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :solid_queue
  end

  after { ActiveJob::Base.queue_adapter = test_adapter }
end
