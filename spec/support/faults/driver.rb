# frozen_string_literal: true

module Faults
  # Breaks things while a storm runs (challenge 30). Every few seconds it
  # starts the next fault. It goes through every kind in an order the seed
  # picks, then through all of them again in a new order, so a run of four
  # faults or more has each kind, and the same seed gives the same order
  # (their timing against the requests is still real time):
  #
  #   cut      every open database connection is closed at once
  #   outage   the database cannot be reached for a moment, then can
  #   restart  PostgreSQL itself restarts, ending every session
  #   clock    the server's clock jumps forward or back, then is put right
  #
  # Lost answers are not here: Faults::LossyTransport loses them the
  # whole time.
  class Driver
    KINDS = %i[cut outage restart clock].freeze
    # Forward past midnight, back an hour, forward a day.
    CLOCK_JUMPS = [6 * 3600, -3600, 86_400].freeze

    attr_reader :log

    def initialize(proxy:, server:, clock:, seed:, every: 2.0)
      @proxy = proxy
      @server = server
      @clock = clock
      @rng = Random.new(seed)
      @every = every
      @log = []
    end

    # Runs until the deadline (a monotonic time), then leaves everything
    # working: the proxy up and the clock right.
    def run(deadline)
      sleep(@every)
      kinds = []
      while Storm::MONOTONIC.call < deadline - @every
        kinds = KINDS.shuffle(random: @rng) if kinds.empty?
        kind = kinds.shift
        @log << [kind, send(kind)]
        sleep(@every)
      end
      self
    ensure
      @proxy.up
      @clock.reset
    end

    private

    def cut = @proxy.cut

    def outage
      @proxy.down
      sleep(1.0)
      @proxy.up
      :back
    end

    def restart
      @server.restart
      :restarted
    end

    def clock
      jump = CLOCK_JUMPS.sample(random: @rng)
      @clock.move(jump)
      sleep(@every / 2)
      @clock.reset
      jump
    end
  end
end
