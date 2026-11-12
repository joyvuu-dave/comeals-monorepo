# frozen_string_literal: true

# The fault suite (challenge 30). bin/faults runs it. It is the
# real-server storm (rake test:storm) with things breaking while it runs:
#
#   - its own PostgreSQL (Faults::Server, under tmp/faults), never the
#     server the worktrees and the development database share;
#   - every database connection, from the server and from this process,
#     goes through a proxy (Faults::Proxy) that the driver cuts, or takes
#     down for a moment;
#   - the driver restarts that PostgreSQL, and moves the server's clock
#     (Faults::Clock) forward and back;
#   - some answers to writes are lost, and the phone sends the same
#     request again (Faults::LossyTransport).
#
# Afterwards: the storm's checks (every meal's ledger, settled meals
# untouched, caps, ledger:verify, the calendar cache), and Faults::Report:
# a write saved but answered with an error when sent again, and a write
# saved twice.
#
#   FAULTS_SECONDS  how long (default 30)
#   FAULTS_CLIENTS  how many phones (default 16)
#   FAULTS_SEED     the seed for the requests and the faults (default 1)
#   FAULTS_LOSE     the chance an answer to a write is lost (default 0.05)
#   FAULTS_EVERY    seconds between faults (default 2)
namespace :test do
  desc 'Run the storm while connections drop, PostgreSQL restarts and the clock moves; check the books after'
  task faults: :environment do
    abort 'Must run in the test environment' unless Rails.env.test?
    require 'net/http'
    Rails.root.glob('spec/support/storm/*.rb').each { |f| require f }
    Rails.root.glob('spec/support/faults/*.rb').each { |f| require f }
    require Rails.root.join('spec/support/random_ledger')

    seconds = Integer(ENV.fetch('FAULTS_SECONDS', 30))
    clients = Integer(ENV.fetch('FAULTS_CLIENTS', 16))
    seed = Integer(ENV.fetch('FAULTS_SEED', 1))
    lose = Float(ENV.fetch('FAULTS_LOSE', 0.05))
    every = Float(ENV.fetch('FAULTS_EVERY', 2))
    root = Rails.root.join('tmp/faults')
    threads = 8

    server = Faults::Server.new(directory: root.join('server'))
    proxy = nil
    puma = nil
    begin
      server.start
      server.create_database('comeals_faults', schema: Rails.root.join('db/structure.sql'))
      proxy = Faults::Proxy.new(upstream_port: server.port)
      database_url = "postgresql://127.0.0.1:#{proxy.port}/comeals_faults"
      clock = Faults::Clock.new(root.join('clock_offset'))
      clock.reset

      ActiveRecord::Base.establish_connection(url: database_url, pool: 12)
      Rails.cache = SolidCache::Store.new(namespace: Rails.env, expiry_method: :job)
      Pusher.define_singleton_method(:trigger) { |*_args| true }

      port = TCPServer.new('127.0.0.1', 0).then { |s| s.addr[1].tap { s.close } }
      server_log = root.join('server_app.log')
      puma = Process.spawn(
        { 'RAILS_ENV' => 'test', 'INTEGRATION_SERVER' => '1', 'INTEGRATION_SERVER_CACHE' => 'solid',
          'DATABASE_URL' => database_url, 'RAILS_MAX_THREADS' => threads.to_s, 'WEB_CONCURRENCY' => '0',
          'RAILS_DB_POOL' => (threads + 2).to_s, 'FAULTS_CLOCK_FILE' => root.join('clock_offset').to_s,
          'RUBYOPT' => "-r#{Rails.root.join('spec/faults/server_clock.rb')}" },
        'bundle', 'exec', 'rails', 'server', '-p', port.to_s, '-b', '127.0.0.1',
        out: server_log.to_s, err: server_log.to_s
      )
      url = URI("http://127.0.0.1:#{port}")
      60.times do
        break if Net::HTTP.get_response(URI("#{url}/api/v1/version")).is_a?(Net::HTTPSuccess)
      rescue SystemCallError
        sleep 1
      end

      ActiveRecord::Base.connection.execute('TRUNCATE communities, ledger_check_runs, job_runs CASCADE')
      Current.reset
      plan = Storm::Seed.plant(clients: clients)

      lock = Mutex.new
      connections = Hash.new { |hash, thread| hash[thread] = Net::HTTP.start(url.host, url.port, read_timeout: 60) }
      plain = lambda do |method, path, headers, body, ip|
        http = lock.synchronize { connections[Thread.current] }
        request = Net::HTTP.const_get(method.to_s.capitalize).new(path)
        headers.each { |name, value| request[name] = value }
        request['X-Forwarded-For'] = ip
        request['Content-Type'] = 'application/json'
        request.body = body if body
        response = http.request(request)
        [Integer(response.code), response.body.to_s]
      end
      transport = Faults::LossyTransport.new(plain, chance: lose, seed: seed)

      puts "==> #{clients} clients for #{seconds}s, a fault every #{every}s, #{(lose * 100).round}% of " \
           "write answers lost (seed #{seed}); PostgreSQL on #{server.port}, through the proxy on #{proxy.port}"
      driver = Faults::Driver.new(proxy: proxy, server: server, clock: clock, seed: seed, every: every)
      deadline = Storm::MONOTONIC.call + seconds
      faults = Thread.new { driver.run(deadline) } # rubocop:disable ThreadSafety/NewThread -- the faults run beside the storm
      result = Storm::Run.call(plan: plan, transport: transport, clients: clients, seconds: seconds, seed: seed)
      faults.join

      lost_connection = /ConnectionFailed|ConnectionNotEstablished|ConnectionBad|DatabaseConnectionError|
                         server\ closed\ the\ connection|terminating\ connection|connection\ to\ server/x
      expected, problems = result.problems.partition { it.match?(lost_connection) }
      # One line for each kind: the action, the status and the error class
      # (the first line of the answer, for an answer with none).
      # A 503 that says the database could not be reached is the right
      # answer while it cannot be (DatabaseUnreachable). Counted, not a problem.
      unreachable, wrong = result.requests.select(&:problem).partition do |e|
        e.status == 503 && e.problem.include?(DatabaseUnreachable::MESSAGE)
      end
      kinds = wrong.group_by do |e|
        [e.action, e.status, e.problem[/\((\w+(?:::\w+)*)\)/, 1] || e.problem.lines.first.to_s[0, 120].strip]
      end
      problems += kinds.map { |(action, status, kind), list| "#{action}: #{status} #{kind} (#{list.size}x)" }
      problems += Storm::Checks.call(plan: plan, transport: plain)
      problems += Faults::Report.error_for_a_saved_write(transport.resends)
      problems += Faults::Report.saved_twice
      connections.each_value(&:finish)

      puts "faults: #{driver.log.map(&:first).tally}"
      puts "background writes stopped by a lost database connection: #{expected.size}"
      puts "requests answered 503, the database could not be reached: #{unreachable.size}"
      puts "requests: #{result.requests.size}, ok writes: #{result.ok_writes}, settlements: #{result.settlements}"
      result.tally.sort.each { |action, statuses| puts "  #{action}: #{statuses.sort_by { |s, _| s.to_s }.to_h}" }
      puts "answers lost and sent again: #{transport.resends.size}"
      Faults::Report.resend_tally(transport.resends).sort.each { |route, tally| puts "  #{route}: #{tally}" }
      if problems.empty?
        puts 'No problems.'
      else
        puts "#{problems.size} problem(s):"
        problems.uniq.first(60).each { |problem| puts "  #{problem}" }
        abort
      end
    ensure
      if puma
        Process.kill('TERM', puma)
        Process.wait(puma)
      end
      proxy&.stop
      server.stop
    end
  end
end
