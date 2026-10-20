# frozen_string_literal: true

require 'rails_helper'

# The checks bin/storm runs after a storm with STORM_SOLID_QUEUE=1, when
# the jobs ran in a real bin/jobs process. Each example plants one thing
# a storm could leave behind and expects the checks to name it.
RSpec.describe Storm::QueueChecks do
  let(:dir) { Pathname(Dir.mktmpdir) }
  let(:jobs_log) { dir.join('storm_jobs.log').tap { |path| path.write("Performed LivePushJob in 2ms\n") } }
  let(:error_log) { dir.join('storm_errors.log').tap { |path| path.write('') } }
  # This process stands in for the jobs process: it is alive.
  let(:pids) { [Process.pid] }

  after { FileUtils.remove_entry(dir) }

  def problems
    described_class.call(jobs_log: jobs_log, error_log: error_log, pids: pids)
  end

  def job(class_name = 'LivePushJob')
    SolidQueue::Job.create!(queue_name: 'default', class_name: class_name, arguments: {},
                            active_job_id: SecureRandom.uuid)
  end

  def worker(heartbeat: Time.current)
    SolidQueue::Process.create!(kind: 'Worker', last_heartbeat_at: heartbeat, pid: 1, hostname: 'storm',
                                name: "worker-#{SecureRandom.hex(4)}")
  end

  def claim(job, process_id)
    job.ready_execution&.destroy!
    SolidQueue::ClaimedExecution.create!(job: job, process_id: process_id)
  end

  def report(**entry)
    error_log.open('a') { |file| file.puts(JSON.generate(Storm::ErrorLog.entry(**entry))) }
  end

  it 'finds nothing after a clean run' do
    claim(job, worker.id)

    expect(problems).to eq([])
  end

  it 'names a job that ended in a failed execution, with its error' do
    failed = job('RefreshBalancesJob')
    failed.ready_execution.destroy!
    SolidQueue::FailedExecution.create!(job: failed, exception: RuntimeError.new('boom'))

    expect(problems).to eq(["job #{failed.id} RefreshBalancesJob failed: RuntimeError: boom"])
  end

  it 'names a job left claimed by a process that is gone' do
    gone = worker
    claimed = job
    claim(claimed, gone.id)
    gone.delete

    expect(problems).to eq(["job #{claimed.id} LivePushJob is claimed by process #{gone.id}, which is gone"])
  end

  it 'names a process whose heartbeat is older than the alive threshold' do
    stale = worker(heartbeat: (SolidQueue.process_alive_threshold + 1.second).ago)

    expect(problems).to contain_exactly(a_string_starting_with("process #{stale.id} (Worker) last beat"))
  end

  it 'names a jobs process that died' do
    dead = Process.spawn('true')
    Process.wait(dead)

    expect(described_class.call(jobs_log: jobs_log, error_log: error_log, pids: [dead]))
      .to eq(["the jobs process (pid #{dead}) died"])
  end

  [
    'ActiveRecord::SerializationFailure: PG::TRSerializationFailure: ERROR:  could not serialize access',
    'SolidQueue-1.7.0 Error in thread (0.0ms)  error: "ActiveRecord::StatementInvalid boom"',
    'Error performing RefreshBalancesJob (Job ID: 1) from SolidQueue(default) in 3.1ms: RuntimeError (boom)',
    'ERROR:  deadlock detected'
  ].each do |line|
    it "names an error line in the jobs log: #{line[0, 40]}" do
      jobs_log.open('a') { |file| file.puts(line) }

      expect(problems).to eq(["jobs log line 2: #{line}"])
    end
  end

  def conflict
    ActiveRecord::SerializationFailure.new('could not serialize access')
  end

  it 'names a push that was not queued after its retries' do
    report(process: 'server', error: conflict, handled: true, context: { channel: 'meal-7' })

    expect(problems).to eq(['server reported and swallowed: ActiveRecord::SerializationFailure: ' \
                            'could not serialize access (channel: meal-7): an enqueue that failed after its retries'])
  end

  it 'lets a conflict that was tried again pass, and counts it' do
    report(process: 'jobs', error: conflict, handled: true, context: { attempt: 1, max_attempts: 5 })

    expect(problems).to eq([])
    expect(described_class.summary(jobs_log: jobs_log, error_log: error_log)).to include(conflicts_retried: 1)
  end

  it 'names an error that was swallowed and is not a conflict' do
    report(process: 'jobs', error: ArgumentError.new('no email'), handled: true, context: {})

    expect(problems).to eq(['jobs reported and swallowed: ArgumentError: no email'])
  end

  it 'names an error a job or a jobs thread raised, and leaves the server and the storm task to their own' do
    report(process: 'jobs', error: RuntimeError.new('thread died'), handled: false, context: {})
    report(process: 'server', error: RuntimeError.new('a 500'), handled: false, context: {})
    report(process: 'driver', error: ActiveRecord::RecordInvalid.new, handled: false, context: {})

    expect(problems).to eq(['jobs raised: RuntimeError: thread died'])
  end

  it 'counts the conflict lines in the jobs log for the report' do
    jobs_log.open('a') { |file| file.puts('PG::TRSerializationFailure: could not serialize access') }

    expect(described_class.summary(jobs_log: jobs_log, error_log: error_log))
      .to include(conflict_lines: 1, failed: 0)
  end

  # The drain reads from another thread's connection here, so its rows
  # must really commit.
  describe '.drain' do
    include_context 'with no test transaction'

    it 'waits for every job up to the mark to finish' do
      waiting = job
      Thread.new do
        sleep(0.2)
        waiting.ready_execution.destroy!
        waiting.update!(finished_at: Time.current)
      end

      expect(described_class.drain(mark: waiting.id, timeout: 5)).to be_nil
    end

    it 'counts a job past the mark as not its business' do
      job
      expect(described_class.drain(mark: 0, timeout: 0.1)).to be_nil
    end

    it 'names the jobs that are still waiting when the time is up' do
      waiting = job

      expect(described_class.drain(mark: waiting.id, timeout: 0.1))
        .to eq('the queue did not drain in 0.1 s: 1 job(s) left ({"LivePushJob" => 1})')
    end
  end
end
