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

    # The settle phone (settle_phone): a reconciler who presses Settle
    # again and again, one cutoff after another, over a connection that
    # loses every answer once, so every settle is sent twice. The storm's
    # own settles are too few in a short run for a lost one to be likely,
    # and at a chance of one half a short run had one settle sent again
    # out of three.
    SETTLE_LOSE = 1.0

    # Every client sends from an address of its own, and the server's
    # throttle counts are not compared with what the clients sent.
    #
    # Shared: a client here never pauses, so four on one address pass
    # Rack::Attack's 600 a minute within seconds. Most of their requests
    # were then 429s, and the run tested the faults on far fewer writes.
    # bin/storm and the RSpec storm test the shared address.
    #
    # Counts: a lost answer is sent again, so the server counts two
    # requests where the client sent one. A request that met a lost
    # database connection may or may not have been counted before it
    # failed, and the client cannot tell which.
    THROTTLE = { shared_address: 1, check_counts: false }.freeze

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
      @settlements = Integer(env.fetch('FAULTS_SETTLEMENTS', 16))
      @root = Rails.root.join('tmp/faults')
    end

    def call
      print_threads_on_usr1
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

    # kill -USR1 <pid> prints where every thread of this process is. The
    # spec sends it to a run that went on too long, before it stops it.
    # The printing runs in a thread of its own, because a signal handler
    # cannot take the lock that writing to the output needs.
    def print_threads_on_usr1
      Signal.trap('USR1') do
        Thread.new do
          Thread.list.each { |thread| @out.puts("--- #{thread.inspect}", thread.backtrace&.first(30)) }
          @out.flush
        end
      end
    end

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
    # COMMITTED and settled a dinner from an old read of its costs. The
    # test database's login is left out: this server was made by initdb
    # with the user running it (Server#initdb), and in CI the test
    # database's user is postgres, a role this server does not have.
    def connect
      settings = ActiveRecord::Base.connection_db_config.configuration_hash.except(:username, :password)
      ActiveRecord::Base.establish_connection(settings.merge(url: database_url, pool: 12))
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
      @plan = Storm::Seed.plant(clients: @clients, settleable: @settlements)
      @plain = plain_transport
      @transport = Faults::LossyTransport.new(@plain, chance: @lose, seed: @seed)
      @out.puts "==> #{@clients} clients for #{@seconds}s, a fault every #{@every}s, #{(@lose * 100).round}% of " \
                "write answers lost (seed #{@seed}); PostgreSQL on #{@server.port}, through the proxy on #{@proxy.port}"
      @driver = Faults::Driver.new(proxy: @proxy, server: @server, clock: @clock, seed: @seed, every: @every)
      deadline = Storm::MONOTONIC.call + @seconds
      faults = Thread.new { @driver.run(deadline) }
      settles = Thread.new { settle_phone(deadline) }
      result = Storm::Run.call(plan: @plan, transport: @transport, clients: @clients, seconds: @seconds, seed: @seed,
                               **THROTTLE)
      faults.join
      settles.join
      result
    end

    # Challenge 30: a settle whose answer is lost and sent again. Each
    # press asks for the plan's next cutoff (Seed::Plan#phone_cutoff), so
    # the presses are spread over the run and most of them settle a
    # dinner, while the storm writes to it, the settler races it, and the
    # driver breaks things. Its answers are counted in @settle_answers and
    # its lost answers in @settle_transport.resends.
    def settle_phone(deadline)
      @settle_answers = Hash.new(0)
      @settle_transport = Faults::LossyTransport.new(@plain, chance: SETTLE_LOSE, seed: @seed + 1)
      token = @plan.tokens.fetch(@plan.reconcilers.first.id)
      pause = @seconds / (@settlements * 1.5)
      press = 0
      while Storm::MONOTONIC.call + pause < deadline
        sleep(pause)
        press += 1
        settle_once(token, press)
      end
    rescue StandardError => e
      @settle_answers["#{e.class}: #{e.message}"] += 1
    end

    def settle_once(token, press)
      cutoff = @plan.phone_cutoff
      headers = { 'Authorization' => "Bearer #{token}", 'Idempotency-Key' => %("settle-phone-#{press}") }
      request = [:post, '/api/v1/reconciliations', headers, JSON.generate(cutoff: cutoff.iso8601), '10.9.99.1']
      status, body = @settle_transport.call(*request)
      @settle_answers[status] += 1
      @plan.phone_settled unless [409, 503].include?(status)
      send_a_settle_again(request, [status, body])
    end

    # The answer that is lost is the first one. When the first send got a
    # conflict (409) or no database (503), nothing was saved, and the send
    # again is the one that settled. Then that settle is sent once more, so
    # every settle that worked is sent again with the same key. Before
    # 2026-11-15 a 12-second run in CI had every first send refused, and
    # no settle that worked was sent again.
    def send_a_settle_again(request, answer)
      return unless answer[0] == 201 && @settle_transport.resends.last&.first_status != 201

      @settle_transport.send_again(request, answer)
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
      problems += Faults::Report.error_for_a_saved_write(@transport.resends + @settle_transport.resends)
      problems += Faults::Report.settle_answered_differently(@settle_transport.resends)
      problems += settle_phone_problems
      problems += Faults::Report.saved_twice
      @connections.each_value(&:finish)
      print_counts(result, expected, unreachable)
      print_problems(problems)
    end

    # The settle phone must have settled at least once, and had at least
    # one of those answers lost and sent again, or the run did not test
    # what it is for. Anything but a settlement (201), nothing left to
    # settle (400), a conflict (409) or the database out of reach (503)
    # is wrong.
    def settle_phone_problems
      wrong = @settle_answers.except(201, 400, 409, 503)
      problems = wrong.map { |status, n| "settle phone: #{status} (#{n}x)" }
      problems << 'settle phone: no settle request succeeded' unless @settle_answers[201].positive?
      unless @settle_transport.resends.any? { it.first_status == 201 }
        problems << 'settle phone: no settle that succeeded was sent again'
      end
      problems
    end

    def print_counts(result, expected, unreachable)
      @out.puts "faults: #{@driver.log.map(&:first).tally}"
      @out.puts "background writes stopped by a lost database connection: #{expected.size}"
      @out.puts "requests answered 503, the database could not be reached: #{unreachable.size}"
      @out.puts "requests: #{result.requests.size}, ok writes: #{result.ok_writes}, settlements: #{result.settlements}"
      result.tally.sort.each { |action, statuses| @out.puts "  #{action}: #{statuses.sort_by { |s, _| s.to_s }.to_h}" }
      @out.puts "settle phone: #{@settle_answers.sort_by { |s, _| s.to_s }.to_h}"
      resends = @transport.resends + @settle_transport.resends
      @out.puts "answers lost and sent again: #{resends.size}"
      Faults::Report.resend_tally(resends).sort.each { |route, tally| @out.puts "  #{route}: #{tally}" }
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
