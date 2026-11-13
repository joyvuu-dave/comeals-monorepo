# frozen_string_literal: true

require 'net/http'

module Faults
  # One run of the fault suite, for rake test:faults (bin/faults). It
  # starts the PostgreSQL, the proxy and the Puma, runs the storm while
  # the driver breaks things, prints what happened, and stops them all.
  # Returns true when it found no problem. What it checks:
  # lib/tasks/test/faults.rake.
  class Session
    THREADS = 8

    # Lines of a background write that the faults stopped on purpose.
    LOST_CONNECTION = /ConnectionFailed|ConnectionNotEstablished|ConnectionBad|DatabaseConnectionError|
                       server\ closed\ the\ connection|terminating\ connection|connection\ to\ server/x

    # out is where it prints: the rake task's standard output.
    def initialize(env, out:)
      @out = out
      @seconds = Integer(env.fetch('FAULTS_SECONDS', 30))
      @clients = Integer(env.fetch('FAULTS_CLIENTS', 16))
      @seed = Integer(env.fetch('FAULTS_SEED', 1))
      @lose = Float(env.fetch('FAULTS_LOSE', 0.05))
      @every = Float(env.fetch('FAULTS_EVERY', 2))
      @root = Rails.root.join('tmp/faults')
    end

    def call
      @server = Faults::Server.new(directory: @root.join('server'))
      @server.start
      @server.create_database('comeals_faults', schema: Rails.root.join('db/structure.sql'))
      @proxy = Faults::Proxy.new(upstream_port: @server.port)
      @clock = Faults::Clock.new(@root.join('clock_offset'))
      @clock.reset
      connect
      start_puma
      report(storm)
    ensure
      stop
    end

    private

    # The port is read into a local: "#{@proxy" right after the host
    # looks like a user, password and host to gitleaks.
    def database_url
      port = @proxy.port
      "postgresql://127.0.0.1:#{port}/comeals_faults"
    end

    # The settler, the jobs and the admin run in this process. Its
    # connections take the app's own settings (the variables: block, so
    # SERIALIZABLE, and the query cache off) with the proxy's address on
    # top. A bare url: has neither, so a settlement here ran at READ
    # COMMITTED and settled a dinner from an old read of its costs.
    def connect
      ActiveRecord::Base.establish_connection(
        ActiveRecord::Base.connection_db_config.configuration_hash.merge(url: database_url, pool: 12)
      )
      TransactionIsolationCheck.verify!(ActiveRecord::Base.connection)
      Rails.cache = SolidCache::Store.new(namespace: Rails.env, expiry_method: :job)
      Pusher.define_singleton_method(:trigger) { |*_args| true }
    end

    def start_puma
      port = TCPServer.new('127.0.0.1', 0).then { |s| s.addr[1].tap { s.close } }
      log = @root.join('server_app.log').to_s
      @puma = Process.spawn(
        { 'RAILS_ENV' => 'test', 'INTEGRATION_SERVER' => '1', 'INTEGRATION_SERVER_CACHE' => 'solid',
          'DATABASE_URL' => database_url, 'RAILS_MAX_THREADS' => THREADS.to_s, 'WEB_CONCURRENCY' => '0',
          'RAILS_DB_POOL' => (THREADS + 2).to_s, 'FAULTS_CLOCK_FILE' => @root.join('clock_offset').to_s,
          'RUBYOPT' => "-r#{Rails.root.join('spec/faults/server_clock.rb')}" },
        'bundle', 'exec', 'rails', 'server', '-p', port.to_s, '-b', '127.0.0.1', out: log, err: log
      )
      @url = URI("http://127.0.0.1:#{port}")
      60.times do
        break if Net::HTTP.get_response(URI("#{@url}/api/v1/version")).is_a?(Net::HTTPSuccess)
      rescue SystemCallError
        sleep 1
      end
    end

    # Plants the rows, then runs the storm and the faults side by side.
    def storm
      ActiveRecord::Base.connection.execute('TRUNCATE communities, ledger_check_runs, job_runs CASCADE')
      Current.reset
      @plan = Storm::Seed.plant(clients: @clients)
      @plain = plain_transport
      @transport = Faults::LossyTransport.new(@plain, chance: @lose, seed: @seed)
      @out.puts "==> #{@clients} clients for #{@seconds}s, a fault every #{@every}s, #{(@lose * 100).round}% of " \
                "write answers lost (seed #{@seed}); PostgreSQL on #{@server.port}, through the proxy on #{@proxy.port}"
      @driver = Faults::Driver.new(proxy: @proxy, server: @server, clock: @clock, seed: @seed, every: @every)
      deadline = Storm::MONOTONIC.call + @seconds
      faults = Thread.new { @driver.run(deadline) }
      result = Storm::Run.call(plan: @plan, transport: @transport, clients: @clients, seconds: @seconds, seed: @seed)
      faults.join
      result
    end

    # One keep-alive connection to the Puma for each thread.
    def plain_transport
      lock = Mutex.new
      @connections = Hash.new { |hash, thread| hash[thread] = Net::HTTP.start(@url.host, @url.port, read_timeout: 60) }
      lambda do |method, path, headers, body, ip|
        http = lock.synchronize { @connections[Thread.current] }
        request = Net::HTTP.const_get(method.to_s.capitalize).new(path)
        headers.each { |name, value| request[name] = value }
        request['X-Forwarded-For'] = ip
        request['Content-Type'] = 'application/json'
        request.body = body if body
        response = http.request(request)
        [Integer(response.code), response.body.to_s]
      end
    end

    def report(result)
      expected, problems = result.problems.partition { it.match?(LOST_CONNECTION) }
      # A 503 that says the database could not be reached is the right
      # answer while it cannot be (DatabaseUnreachable). Counted, not a problem.
      unreachable, wrong = result.requests.select(&:problem).partition do |e|
        e.status == 503 && e.problem.include?(DatabaseUnreachable::MESSAGE)
      end
      problems += kinds(wrong)
      # The checks read through the server too, with no answer lost.
      problems += Storm::Checks.call(plan: @plan, transport: @plain)
      problems += Faults::Report.error_for_a_saved_write(@transport.resends)
      problems += Faults::Report.saved_twice
      @connections.each_value(&:finish)
      print_counts(result, expected, unreachable)
      print_problems(problems)
    end

    def print_counts(result, expected, unreachable)
      @out.puts "faults: #{@driver.log.map(&:first).tally}"
      @out.puts "background writes stopped by a lost database connection: #{expected.size}"
      @out.puts "requests answered 503, the database could not be reached: #{unreachable.size}"
      @out.puts "requests: #{result.requests.size}, ok writes: #{result.ok_writes}, settlements: #{result.settlements}"
      result.tally.sort.each { |action, statuses| @out.puts "  #{action}: #{statuses.sort_by { |s, _| s.to_s }.to_h}" }
      @out.puts "answers lost and sent again: #{@transport.resends.size}"
      Faults::Report.resend_tally(@transport.resends).sort.each { |route, tally| @out.puts "  #{route}: #{tally}" }
    end

    # One line for each kind of wrong answer: the action, the status and
    # the error class (the first line of the answer, for an answer with
    # none).
    def kinds(wrong)
      groups = wrong.group_by do |e|
        [e.action, e.status, e.problem[/\((\w+(?:::\w+)*)\)/, 1] || e.problem.lines.first.to_s[0, 120].strip]
      end
      groups.map { |(action, status, kind), list| "#{action}: #{status} #{kind} (#{list.size}x)" }
    end

    # Prints the problems, or that there are none. True when there are none.
    def print_problems(problems)
      if problems.empty?
        @out.puts 'No problems.'
        return true
      end

      @out.puts "#{problems.size} problem(s):"
      problems.uniq.first(60).each { |problem| @out.puts "  #{problem}" }
      false
    end

    def stop
      if @puma
        Process.kill('TERM', @puma)
        Process.wait(@puma)
      end
      @proxy&.stop
      @server&.stop
    end
  end
end
