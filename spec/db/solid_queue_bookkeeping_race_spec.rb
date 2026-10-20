# frozen_string_literal: true

require 'rails_helper'

# Solid Queue's worker, dispatcher and scheduler keep their own records in
# the solid_queue_* tables: which jobs are ready, which a worker has
# claimed, which are scheduled for later, and so on. Every session runs at
# SERIALIZABLE (ADR 0005), so PostgreSQL checks these writes against each
# other and against the app's own transactions, and cancels one when two
# transactions read what the other one writes. Solid Queue does not retry
# its own transactions, so each cancel is a lost step and an error report.
#
# Each example runs the gem's own methods on real job rows, on two
# connections, so that each transaction reads before the other one writes
# (spec/support/at_the_same_moment.rb). Each one fails at SERIALIZABLE.
#
# spec/db/solid_queue_process_rows_race_spec.rb has the heartbeat and the
# shutdown.
RSpec.describe "Solid Queue's own bookkeeping, at the same moment as other writes" do
  include_context 'with no test transaction'
  include_context 'with Solid Queue as the job adapter'

  let!(:worker) do
    SolidQueue::Process.register(kind: 'Worker', name: 'worker-test', pid: 1, hostname: 'test', metadata: {})
  end

  before { stub_const('ProbeJob', Class.new(ApplicationJob) { def perform = nil }) }

  # The worker's poll: claim one ready job (SolidQueue::Worker#poll).
  def claim = SolidQueue::ReadyExecution.claim(['*'], 1, worker.id)

  def claim_reads_ready = /\ASELECT .* FROM "solid_queue_ready_executions" .* FOR UPDATE SKIP LOCKED/

  def open_session
    db = ActiveRecord::Base.connection_db_config.configuration_hash
    PG.connect(host: db[:host], port: db[:port], user: db[:username], password: db[:password], dbname: db[:database])
  end

  # A worker's poll reads solid_queue_ready_executions. An app transaction
  # that queues a job writes a row there. That is one dependency: the poll
  # comes first. If the app transaction also read a row that a third
  # transaction changed and committed, the app transaction comes before
  # that one too. PostgreSQL then cancels the app transaction, even though
  # without the poll it would have committed. So the poll can make the
  # settlement fail, and its mail jobs with it.
  it 'commits an app transaction that queues a job while the worker polls, when a row it read has changed' do
    ProbeJob.perform_later
    community = create(:community)
    app_transaction = lambda do
      ActiveRecord::Base.transaction do
        Community.find(community.id)
        ProbeJob.perform_later
      end
    end

    outcomes = at_the_same_moment([claim_reads_ready, -> { claim }],
                                  [/\ASELECT .* FROM "communities"/, app_transaction]) do
      # A web request at SERIALIZABLE, like every Rails session.
      other = open_session
      other.exec('BEGIN ISOLATION LEVEL SERIALIZABLE')
      other.exec("UPDATE communities SET updated_at = now() WHERE id = #{community.id}")
      other.exec('COMMIT')
      other.close
    end

    expect(outcomes).to eq(%i[ok ok])
    expect(SolidQueue::Job.count).to eq(2)
  end

  # The dispatcher moves a due job from solid_queue_scheduled_executions to
  # solid_queue_ready_executions, and then reads that table again to see
  # which jobs it moved. A worker's poll reads the ready table and deletes
  # the row it claims. Each one reads what the other writes.
  it 'moves a due scheduled job to ready while the worker claims another job' do
    ProbeJob.perform_later
    ProbeJob.set(wait: 1.minute).perform_later
    SolidQueue::ScheduledExecution.update_all(scheduled_at: 1.minute.ago)

    outcomes = at_the_same_moment(
      [/\ASELECT .* FROM "solid_queue_scheduled_executions" .* FOR UPDATE SKIP LOCKED/,
       -> { SolidQueue::ScheduledExecution.dispatch_next_batch(100) }],
      [claim_reads_ready, -> { claim }],
      sequential_scans: true
    )

    expect(outcomes).to eq(%i[ok ok])
    expect([SolidQueue::ReadyExecution.count, SolidQueue::ClaimedExecution.count]).to eq([1, 1])
  end

  # When a job has run, the worker marks it finished and deletes its claim
  # (SolidQueue::ClaimedExecution#perform). A poll for the next job reads
  # the claimed table too, when it looks up the claim it has just made.
  it 'finishes a job while the worker claims the next one' do
    ProbeJob.perform_later
    running = claim.first
    ProbeJob.perform_later

    outcomes = at_the_same_moment(
      [/\AUPDATE "solid_queue_jobs" SET "finished_at"/, -> { SolidQueue::ClaimedExecution.find(running.id).perform }],
      [claim_reads_ready, -> { claim }],
      sequential_scans: true
    )

    expect(outcomes).to eq(%i[ok ok])
    expect(SolidQueue::Job.where.not(finished_at: nil).count).to eq(1)
    expect(SolidQueue::ClaimedExecution.count).to eq(1)
  end
end
