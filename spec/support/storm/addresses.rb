# frozen_string_literal: true

module Storm
  # Which address each client sends from, and how many requests went from
  # each address in each throttle window, counted across every client on
  # that address.
  #
  # The first `shared` clients send from one address, the way everyone at
  # the Common House iPad, or in homes that share one internet connection,
  # does. Every other client has an address of its own. Until #292 every
  # client had its own, so no storm ever sent two requests from one
  # address at once, and none saw that Rack::Attack lost counts when they
  # did (spec/concurrency/shared_address_spec.rb).
  #
  # Two things are judged with these counts:
  #
  #   - a 429 had grounds: the address, all its clients together, sent
  #     more than the limit in that window or the one before (a request
  #     sent at a window's edge may be counted in the next);
  #   - the server counted every request: for each address, its
  #     throttle_counts rows for the API rule add up to what its clients
  #     sent in those windows. A count can be off by the requests in
  #     flight at the two edges, at most one per client per edge. A lost
  #     count (#292) is off by hundreds.
  #
  # Client threads share one of these, so every read and write of the
  # counts is under the lock.
  class Addresses
    # config/initializers/rack_attack.rb
    API_LIMIT = 600
    API_PERIOD = 60
    LOGIN_LIMIT = 20
    LOGIN_PERIOD = 300
    SHARED = '10.9.255.1'

    def initialize(shared:)
      @shared = shared
      @sent = Hash.new(0)
      @lock = Mutex.new
    end

    def address_for(index)
      return SHARED if @shared > 1 && index < @shared

      "10.9.#{index / 250}.#{(index % 250) + 1}"
    end

    def note_sent(address, login, now = Time.now.to_i)
      @lock.synchronize do
        @sent[[address, API_PERIOD, now / API_PERIOD]] += 1
        @sent[[address, LOGIN_PERIOD, now / LOGIN_PERIOD]] += 1 if login
      end
    end

    def throttled_with_reason?(address, login, now = Time.now.to_i)
      @lock.synchronize do
        over?(address, API_PERIOD, API_LIMIT, now) || (login && over?(address, LOGIN_PERIOD, LOGIN_LIMIT, now))
      end
    end

    # What this address sent, per rule and window, for a problem's text.
    def sent_from(address)
      @lock.synchronize { @sent.select { |(from, *), _| from == address }.transform_keys { |key| key.drop(1) } }
    end

    # One problem for each address whose API count on the server is not
    # what its clients sent. With the queue running (bin/storm
    # STORM_SOLID_QUEUE=1), the hourly cleanup runs every few seconds and
    # deletes the rows of windows that ended, so a window with no row is
    # left out. Without it nothing deletes a row, so an address that sent
    # requests and has no row at all is a problem too: the counts went
    # somewhere else, and nothing was checked.
    def count_problems(clients:, rows_may_be_deleted: false)
      by_address(clients).filter_map do |address, on_it|
        counted = counts_for(address)
        next if counted.empty? && rows_may_be_deleted
        next "address #{address}: the server has no throttle_counts row for it" if counted.empty?

        server, sent = server_and_sent(address, counted)
        next if (server - sent).abs <= 2 * on_it

        "address #{address} (#{on_it} clients): the server counted #{server} API requests " \
          "in windows #{counted.keys.sort.inspect}, but its clients sent #{sent}"
      end
    end

    # One line for the report: the shared address's count on the server,
    # and what its clients sent, so a run shows the check ran.
    def summary(clients:)
      on_it = by_address(clients).fetch(SHARED, 0)
      return 'throttle counts: no shared address (STORM_SHARED_ADDRESS=1)' if on_it.zero?

      server, sent = server_and_sent(SHARED, counts_for(SHARED))
      "throttle counts: #{SHARED} (#{on_it} clients) sent #{sent} API requests, the server counted #{server}"
    end

    private

    def by_address(clients)
      Array.new(clients) { |index| address_for(index) }.tally
    end

    # The server's API count for the address, by window.
    def counts_for(address)
      ThrottleCount.where('key LIKE ?', "rack::attack:%:api/ip:#{address}").pluck(:key, :count)
                   .to_h { |key, count| [Integer(key[/\Arack::attack:(\d+):/, 1]), count] }
    end

    def server_and_sent(address, counted)
      sent = @lock.synchronize { counted.keys.sum { |window| @sent[[address, API_PERIOD, window]] } }
      [counted.values.sum, sent]
    end

    def over?(address, period, limit, now)
      window = now / period
      @sent[[address, period, window]] > limit || @sent[[address, period, window - 1]] > limit
    end
  end
end
