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

    def self.call(**)
      new(**).call
    end

    # network: the first three parts of an IPv4 address, such as
    # "10.8.0". Give each measurement its own, so the throttle never
    # counts two of them together.
    def initialize(plan:, transport:, network:, seconds: SECONDS, give_up_after: Refusals::GIVE_UP_AFTER)
      @path = "/api/v1/meals/#{plan.baseline_meal.id}/residents/#{plan.residents.first.id}"
      @headers = { 'Authorization' => "Bearer #{plan.tokens.fetch(plan.residents.first.id)}" }
      @transport = transport
      @network = network
      @seconds = seconds
      @give_up_after = give_up_after
      @sent = 0
      @conflicts = 0
    end

    # On its own thread, the way a storm client runs, so it checks out a
    # connection of its own. `value` raises the thread's error again here,
    # so Ruby's own report of it would only print a copy.
    def call
      Thread.new do
        Thread.current.report_on_exception = false
        measure
      end.value
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

    # A 409 is sent again, as a client would (Refusals says why a write
    # alone can be refused). The count is shown in the storm's summary.
    # The time a conflict took stays in the measurement, which can only
    # lower the floor.
    def write(method, body)
      label = "baseline #{method} #{@path}"
      status, response = Refusals.retry(label, give_up_after: @give_up_after, on_conflict: -> { @conflicts += 1 }) do
        @transport.call(method, @path, @headers, JSON.generate(body), address)
      end
      raise "#{label} answered #{status}: #{response.to_s[0, 300]}" unless status == 200
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
