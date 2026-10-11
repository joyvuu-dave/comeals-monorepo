# frozen_string_literal: true

require 'json'

module Storm
  # How many meal writes a second one client gets answered on this
  # machine right now, with nothing else running. The request storm's
  # floor for meal writes per second is a share of this (#131).
  #
  # One client signs up for a meal and leaves it again, over and over,
  # for two seconds. Those are the storm's most common writes, sent
  # through the same transport and Rack stack, under the same meal lock,
  # in the same kind of SERIALIZABLE transaction, from the same process
  # to the same database. So whatever makes this machine slow (other test
  # suites, a laptop on battery, a small CI runner) slows this client and
  # the storm alike.
  #
  # The meal is plan.baseline_meal. No client, settler or admin in the
  # storm writes to it, so a measurement after the storm finds the meal
  # as a measurement before it did.
  class Baseline
    Result = Struct.new(:rate, :conflicts, keyword_init: true) do
      def to_s
        format('%<rate>.1f meal writes/s (%<conflicts>d answered 409)', rate: rate, conflicts: conflicts)
      end
    end

    SECONDS = 2.0
    # The first requests on a new thread check out a connection and fill
    # caches. They are sent but not timed.
    WARMUP_PAIRS = 5
    # The API throttle allows 600 requests a minute from one address
    # (config/initializers/rack_attack.rb). A fast machine could send that
    # many in one measurement, so the address changes every 100 requests.
    REQUESTS_PER_ADDRESS = 100
    # How many times in a row one write is sent again after a 409.
    MAX_TRIES = 10

    def self.call(**)
      new(**).call
    end

    # network: the first three parts of an IPv4 address, such as
    # "10.8.0". Give each measurement its own, so the throttle never
    # counts two of them together.
    def initialize(plan:, transport:, network:, seconds: SECONDS)
      @path = "/api/v1/meals/#{plan.baseline_meal.id}/residents/#{plan.residents.first.id}"
      @headers = { 'Authorization' => "Bearer #{plan.tokens.fetch(plan.residents.first.id)}" }
      @transport = transport
      @network = network
      @seconds = seconds
      @sent = 0
      @conflicts = 0
    end

    # On its own thread, the way a storm client runs, so it checks out a
    # connection of its own.
    def call
      Thread.new { measure }.value
    end

    private

    def measure
      WARMUP_PAIRS.times { write_pair }
      writes = 0
      started = now
      while now - started < @seconds
        write_pair
        writes += 2
      end
      Result.new(rate: writes / (now - started), conflicts: @conflicts)
    end

    def write_pair
      write(:post, { late: false, vegetarian: false })
      write(:delete, {})
    end

    # A 409 is sent again, as a client would, up to MAX_TRIES times in a
    # row. Alone there should be nothing to conflict with, so the count
    # is shown in the storm's summary. The time a conflict took stays in
    # the measurement, which can only lower the floor.
    def write(method, body)
      MAX_TRIES.times do
        status, response = @transport.call(method, @path, @headers, JSON.generate(body), address)
        return if status == 200
        raise "baseline #{method} #{@path} answered #{status}: #{response.to_s[0, 300]}" unless status == 409

        @conflicts += 1
      end
      raise "baseline #{method} #{@path} answered 409 #{MAX_TRIES} times in a row, with nothing else running"
    end

    def address
      @sent += 1
      "#{@network}.#{(@sent / REQUESTS_PER_ADDRESS) + 1}"
    end

    def now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
