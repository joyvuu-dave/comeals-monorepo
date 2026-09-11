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

    ActiveRecord::Base.connection.execute('TRUNCATE communities, ledger_check_runs, job_runs CASCADE')
    Current.reset
    plan = Storm::Seed.plant(clients: clients)

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
    result = Storm::Run.call(plan: plan, transport: transport, clients: clients, seconds: seconds, seed: seed)
    connections.each_value(&:finish)

    problems = result.requests.filter_map { |e| e.problem && "client #{e.client} ##{e.n} #{e.action}: #{e.problem}" }
    problems += result.problems
    problems += Storm::Checks.call(plan: plan, transport: transport)

    puts "requests: #{result.requests.size}, ok writes: #{result.ok_writes}, settlements: #{result.settlements}"
    result.tally.sort.each { |action, statuses| puts "  #{action}: #{statuses.sort_by { |s, _| s.to_s }.to_h}" }
    puts "background: #{result.background_tally}"
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
