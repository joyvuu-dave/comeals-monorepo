# frozen_string_literal: true

require 'rails_helper'

# The test job adapter is one object for the whole run (rails_helper.rb).
# Until 2026-10-09 the jobs one example enqueued or performed were still
# in its lists in every later example. Nothing noticed while the specs ran
# in one fixed order. In a random order (seed 52964), a cook mail job from
# an earlier settlement was still enqueued when
# settle_and_notify_cache_clear_refused_spec.rb asked have_been_enqueued
# about its own one. The matcher looked up the reconciliation of each
# NotifyCooksJob in the list, and prosopite failed the example for running
# the same query twice.
#
# The second example must run right after the first, so this group keeps
# its own order.
RSpec.describe 'The job lists between examples', order: :defined do
  let(:adapter) { ActiveJob::Base.queue_adapter }

  it 'gets a job enqueued and a push performed in one example' do
    expect do
      RefreshBalancesJob.perform_later
      LivePushJob.perform_later('community-1', { 'version' => 1 })
    end.to change { adapter.enqueued_jobs.size }.by(1).and change { adapter.performed_jobs.size }.by(1)
  end

  it 'starts the next example with nothing enqueued and nothing performed' do
    expect(adapter.enqueued_jobs).to eq([])
    expect(adapter.performed_jobs).to eq([])
  end
end
