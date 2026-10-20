# frozen_string_literal: true

# The real-server storm. bin/storm boots a Puma with many threads and
# workers on this worktree's test port and then runs this task, which
# plants the rows, hits the server from many client threads over TCP,
# runs the settler, the nightly jobs and an admin in this process (the
# rake dynos and the admin are other processes in production too), and
# then checks the database the way the in-process storm does.
#
# The client, the runner and the checks are the in-process storm's
# (spec/support/storm); only the transport differs.
#
#   STORM_URL      where the server is (bin/storm sets it)
#   STORM_SECONDS  how long (default 20)
#   STORM_CLIENTS  how many phones (default 64)
#   STORM_SEED     the random seed (default 1)
#   STORM_MAX_P95  fail when the p95 round trip, in ms, is above this (off by default)
#   STORM_SOLID_QUEUE     1 to queue and run the jobs through a real Solid Queue:
#                         this task starts bin/jobs after the seed and checks the
#                         queue after the storm (Storm::JobsProcess, Storm::QueueChecks)
#   STORM_JOBS_PROCESSES  how many bin/jobs processes (default 1; 2 is a deploy's overlap)
#   STORM_SQ_DRAIN        how long to wait for the queue to drain after the storm (default 300 s)
#   STORM_ERROR_LOG       the file every process writes its Rails.error reports to
#                         (Storm::ErrorLog); checked after the storm when set
#
# Every run prints the round-trip times it saw, per action and overall,
# and saves them under tmp/storm_latency.json keyed by the run's shape
# (clients and seconds); the next run of the same shape prints the
# change. The numbers are this machine's, so compare like with like.
namespace :test do
  desc 'Hit a running test server with a storm of concurrent requests and check the books after'
  task storm: :environment do
    abort 'Must run in the test environment' unless Rails.env.test?
    require 'net/http'
    Rails.root.glob('spec/support/storm/*.rb').each { |f| require f }
    require Rails.root.join('spec/support/random_ledger')

    url = URI(ENV.fetch('STORM_URL'))
    seconds = Integer(ENV.fetch('STORM_SECONDS', 20))
    clients = Integer(ENV.fetch('STORM_CLIENTS', 64))
    seed = Integer(ENV.fetch('STORM_SEED', 1))

    # This process writes too (the settler, the jobs, the admin), and each
    # of those threads needs a connection; the pool is sized for them.
    ActiveRecord::Base.establish_connection(
      ActiveRecord::Base.connection_db_config.configuration_hash.merge(pool: 12)
    )
    # The server caches in solid_cache (INTEGRATION_SERVER_CACHE, set by
    # bin/storm); the checks clear that cache from here, so this process
    # must look at the same table under the same namespace.
    Rails.cache = SolidCache::Store.new(namespace: Rails.env, expiry_method: :job)
    Pusher.define_singleton_method(:trigger) { |*_args| true }

    queue = ENV['STORM_SOLID_QUEUE'].present?
    tables = %w[communities ledger_check_runs job_runs]
    tables += %w[solid_queue_jobs solid_queue_processes solid_queue_semaphores solid_queue_recurring_tasks] if queue
    ActiveRecord::Base.connection.execute("TRUNCATE #{tables.join(', ')} CASCADE")
    Current.reset
    plan = Storm::Seed.plant(clients: clients)

    jobs = []
    if queue
      count = Integer(ENV.fetch('STORM_JOBS_PROCESSES', 1))
      jobs = Array.new(count) do |i|
        Storm::JobsProcess.new(log: Rails.root.join(i.zero? ? 'tmp/storm_jobs.log' : "tmp/storm_jobs_#{i + 1}.log"))
      end
      jobs.each(&:start)
      # Stopped after the checks, and here too when the task stops
      # early (abort, an error): a stop that already ran does nothing.
      at_exit { jobs.each(&:stop) }
      Rails.root.join('tmp/storm_jobs.pid').write(jobs.map(&:pid).join("\n"))
      jobs.each(&:wait_until_registered)
      puts "==> #{count} bin/jobs process(es) running: pid #{jobs.map(&:pid).join(', ')}, " \
           "heartbeat #{SolidQueue.process_heartbeat_interval.inspect}, " \
           "alive threshold #{SolidQueue.process_alive_threshold.inspect}"
    end

    # One connection per client thread, kept open; the client's IP rides
    # in X-Forwarded-For, which Rack trusts from the loopback proxy.
    connections = Hash.new do |hash, thread|
      hash[thread] = Net::HTTP.start(url.host, url.port, read_timeout: 60)
    end
    lock = Mutex.new
    transport = lambda do |method, path, headers, body, ip|
      http = lock.synchronize { connections[Thread.current] }
      request = Net::HTTP.const_get(method.to_s.capitalize).new(path)
      headers.each { |name, value| request[name] = value }
      request['X-Forwarded-For'] = ip
      request['Content-Type'] = 'application/json'
      request.body = body if body
      response = http.request(request)
      [Integer(response.code), response.body.to_s]
    end

    puts "==> #{clients} clients for #{seconds}s against #{url} (seed #{seed})"
    result = Storm::Run.call(plan: plan, transport: transport, clients: clients, seconds: seconds, seed: seed,
                             queue_jobs: queue)

    problems = result.requests.filter_map { |e| e.problem && "client #{e.client} ##{e.n} #{e.action}: #{e.problem}" }
    problems += result.problems
    # Before the checks below, which write too: the queue is checked
    # with the jobs process still running, and again after it stopped.
    queue_summary = nil
    if queue
      error_log = ENV.fetch('STORM_ERROR_LOG', '')
      problems += Storm::QueueChecks.after_storm(jobs: jobs, error_log: error_log, say: method(:puts),
                                                 drain_timeout: Float(ENV.fetch('STORM_SQ_DRAIN', 300)))
      queue_summary = Storm::QueueChecks.summary(jobs_log: jobs.first.log, error_log: error_log)
    elsif ENV['STORM_ERROR_LOG'].present?
      problems += Storm::ErrorLog.read(ENV.fetch('STORM_ERROR_LOG')).filter_map { |e| Storm::ErrorLog.problem(e) }
    end
    problems += Storm::Checks.call(plan: plan, transport: transport)
    # After the checks: they send requests too, on a connection of their own.
    connections.each_value(&:finish)

    puts "requests: #{result.requests.size}, meal writes: #{result.meal_write_attempts} " \
         "from #{result.clients_that_wrote} clients, ok writes: #{result.ok_writes} " \
         "(#{result.ok_row_writes} rows), settlements: #{result.settlements}"
    result.tally.sort.each { |action, statuses| puts "  #{action}: #{statuses.sort_by { |s, _| s.to_s }.to_h}" }
    puts "background: #{result.background_tally}"
    puts "queue: #{queue_summary}" if queue_summary

    latency = result.latency
    puts latency.report
    shape = "#{clients} clients, #{seconds}s"
    previous = Storm::Latency.record(latency, path: Rails.root.join('tmp/storm_latency.json'), shape: shape)
    puts Storm::Latency.compare(latency, previous)
    if ENV['STORM_MAX_P95'] && latency.overall.p95 > Float(ENV.fetch('STORM_MAX_P95'))
      problems << "p95 round trip #{latency.overall.p95} ms is above STORM_MAX_P95=#{ENV.fetch('STORM_MAX_P95')}"
    end
    if problems.empty?
      puts 'No problems.'
    else
      puts "#{problems.size} problem(s):"
      problems.uniq.first(40).each { |problem| puts "  #{problem}" }
      abort
    end
    abort 'the storm did not settle anything' if result.settlements.zero?
  end
end
