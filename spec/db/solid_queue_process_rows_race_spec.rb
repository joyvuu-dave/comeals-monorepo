# frozen_string_literal: true

require 'rails_helper'

# Every Solid Queue process (the supervisor, the dispatcher, the worker and
# the scheduler) has a row in solid_queue_processes. Every 60 seconds each
# one writes the time into its own row (SolidQueue::Process#heartbeat):
#
#   BEGIN
#   SELECT * FROM solid_queue_processes WHERE id = $1 LIMIT 1 FOR UPDATE
#   UPDATE solid_queue_processes SET last_heartbeat_at = $1 WHERE id = $2
#   COMMIT
#
# The processes start together, so their heartbeats often run at the same
# moment. Every session runs at SERIALIZABLE (ADR 0005), and at
# SERIALIZABLE each heartbeat reads the row the other one writes:
#
#   - with a few rows in the table, PostgreSQL reads it with a sequential
#     scan, and that counts as a read of the whole table;
#   - with an index scan, it counts as a read of the primary key's index
#     page, and the UPDATE adds a new entry to that same page, because
#     last_heartbeat_at has an index of its own.
#
# So there are two read/write dependencies, one in each direction.
# PostgreSQL cannot put the two transactions in any order, and it cancels
# one with ActiveRecord::SerializationFailure. Solid Queue does not retry
# it: the heartbeat is lost, and the error is reported as unhandled.
#
# On shutdown the supervisor stops all its processes at once, and each
# one deletes its own row (SolidQueue::Process#deregister). With a
# sequential scan each DELETE reads the whole table too, so two of them
# fail the same way. (With an index scan they do not: a DELETE adds no
# index entry.) PostgreSQL picks a sequential scan for a table this small
# once it has statistics for it, which a long-running database has and a
# freshly emptied test table does not, so that example turns index scans
# off.
#
# Each example makes both transactions read before either one writes,
# which is the order that fails (spec/support/at_the_same_moment.rb).
RSpec.describe 'two Solid Queue processes writing their own rows at the same moment' do
  include_context 'with no test transaction'

  let(:supervisor) { register('Supervisor(async)', 'supervisor-test') }
  let!(:dispatcher) { register('Dispatcher', 'dispatcher-test', supervisor: supervisor) }
  let!(:worker) { register('Worker', 'worker-test', supervisor: supervisor) }

  def reload(process) = SolidQueue::Process.find(process.id)

  def register(kind, name, supervisor: nil)
    SolidQueue::Process.register(kind: kind, name: name, pid: 1, hostname: 'test', supervisor: supervisor,
                                 metadata: {})
  end

  it 'records both heartbeats, with no error' do
    an_hour_ago = 1.hour.ago
    SolidQueue::Process.where(id: [dispatcher.id, worker.id]).update_all(last_heartbeat_at: an_hour_ago)

    outcomes = at_the_same_moment([/\ASELECT .* FOR UPDATE\z/, -> { reload(dispatcher).heartbeat }],
                                  [/\ASELECT .* FOR UPDATE\z/, -> { reload(worker).heartbeat }])

    expect(outcomes).to eq(%i[ok ok])
    expect(SolidQueue::Process.where(id: [dispatcher.id, worker.id]).pluck(:last_heartbeat_at))
      .to all(be > an_hour_ago)
  end

  it 'removes both rows when the two processes shut down at the same moment, with no error' do
    outcomes = at_the_same_moment([/\ADELETE FROM "solid_queue_processes"/, -> { reload(dispatcher).deregister }],
                                  [/\ADELETE FROM "solid_queue_processes"/, -> { reload(worker).deregister }],
                                  sequential_scans: true)

    expect(outcomes).to eq(%i[ok ok])
    expect(SolidQueue::Process.where(id: [dispatcher.id, worker.id])).to be_empty
  end
end
