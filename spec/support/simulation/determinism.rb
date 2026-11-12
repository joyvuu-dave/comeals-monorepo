# frozen_string_literal: true

module Simulation
  # While a simulation runs, the clock, sleep and randomness come from the
  # seed, so a replay sees the same times and the same random values. Only
  # one actor runs at a time, so one clock and one generator for the whole
  # process give every actor the same values in the same order.
  #
  #   - Time.now (and so Time.current, Time.zone.now, the throttle windows,
  #     token times) reads the simulation's clock. The clock moves forward
  #     one tick each time the scheduler gives an actor its turn.
  #   - sleep, called by an actor, puts that actor aside until the clock
  #     reaches the time it asked for. Other actors run meanwhile, and when
  #     nothing else can run the clock jumps to the earliest wake time. So
  #     sleeps overlap the way real ones do, and nobody waits in real time.
  #     Called by any other thread, sleep really sleeps.
  #   - SecureRandom, and rand called by an actor (Kernel.rand, rand,
  #     Random.rand), draw from one generator seeded from the simulation's
  #     seed. Seeding Ruby's shared generator with srand was not enough:
  #     other code in the process draws from it between two runs.
  #
  # Outside a simulation all of them behave as normal. Not covered:
  # Process.clock_gettime (Rails times its own instrumentation with it,
  # and nothing the app decides reads it), and PostgreSQL's own clock
  # (now(), CURRENT_TIMESTAMP), which the seed data step handles.
  module Determinism
    TICK = 0.001

    class Clock
      # In seconds since the epoch, as a Rational, so sums are exact.
      attr_reader :at

      def initialize(start)
        @at = start.to_r
      end

      def now = Time.at(@at).utc

      def advance(seconds)
        @at += seconds.to_r
      end

      def move_to(at)
        @at = at if at > @at
      end
    end

    # The one simulation running in this process, on purpose process-wide:
    # the clock and the generators are shared by every actor thread, and
    # only one actor runs at a time. A second simulation is refused.
    # rubocop:disable ThreadSafety/ClassInstanceVariable
    @current = nil

    class << self
      attr_reader :current

      # The seeded generator, when the calling thread is an actor's.
      def actor_random
        state = @current
        state.random if state&.actor_threads&.include?(Thread.current)
      end

      # Runs the block with the seeded clock and generators in place.
      # Not reentrant: one simulation at a time.
      def with(seed:, start:)
        raise 'a simulation is already running' if @current

        begin
          @current = State.new(Clock.new(start), Random.new(seed), Concurrent::Set.new, nil)
          put_back = TimeNow.install
          yield @current
        ensure
          put_back&.call
          @current = nil
        end
      end
    end
    # rubocop:enable ThreadSafety/ClassInstanceVariable

    # sleeper is set by the scheduler: it puts the calling actor aside.
    State = Struct.new(:clock, :random, :actor_threads, :sleeper)

    # Time.now is replaced only while a simulation runs, and what was
    # there is put back after, even a travel_to stub. Not a module
    # prepended to Time for good, as sleep and rand are: travel_to stubs
    # Time.now by renaming it and puts it back the same way, which copied
    # the prepended method into Time, where its super called itself
    # forever. That broke every spec that used travel_to.
    module TimeNow
      def self.install
        before = Time.method(:now)
        clock = Determinism.current.clock
        Time.define_singleton_method(:now) { |*| clock.now.getlocal }
        -> { Time.define_singleton_method(:now, before) }
      end
    end

    module Sleep
      private

      def sleep(seconds = nil)
        state = Determinism.current
        return super unless state&.actor_threads&.include?(Thread.current)
        raise ArgumentError, 'an actor cannot sleep forever in a simulation' if seconds.nil?

        state.sleeper.call(seconds)
        seconds.round
      end
    end

    # Kernel.rand and Random.rand take a maximum of 0 or nil to mean a
    # float; Random#rand does not.
    module SeededRand
      def rand(max = nil)
        random = Determinism.actor_random
        return super unless random

        if max.nil? || max == 0 # a Range has no zero?
          random.rand
        else
          random.rand(max.is_a?(Range) ? max : max.abs)
        end
      end
    end

    # Only on an actor's thread: other threads in the process (Rails makes
    # an id for each thread's instrumenter) would draw from the same
    # generator at times the seed does not decide.
    module SeededBytes
      def random_bytes(size = nil)
        random = Determinism.actor_random
        random ? random.bytes(size || 16) : super
      end

      def gen_random(size)
        random = Determinism.actor_random
        random ? random.bytes(size) : super
      end

      def random_number(*)
        random = Determinism.actor_random
        random ? random.rand(*) : super
      end
    end
  end
end

Object.prepend(Simulation::Determinism::Sleep)
SecureRandom.singleton_class.prepend(Simulation::Determinism::SeededBytes)
Object.prepend(Simulation::Determinism::SeededRand)
Kernel.singleton_class.prepend(Simulation::Determinism::SeededRand)
Random.singleton_class.prepend(Simulation::Determinism::SeededRand)
