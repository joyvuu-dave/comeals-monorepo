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
  # Outside a simulation they are Ruby's own methods (Hooks, below). Not covered:
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
          put_back = Hooks.install
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

    # Every hook is in place only while a simulation runs, and what was
    # there before is put back after, even a stub. A module prepended for
    # good would stay in every spec of the test run: travel_to stubs
    # Time.now by renaming it and puts it back the same way, and that
    # copied a prepended Time.now into Time, where its super called itself
    # forever. That broke every spec that used travel_to.
    module Hooks
      # Each hook as [class or module, method name, body]. A body gets
      # Ruby's own method, bound to the receiver, then the arguments.
      LIST = [
        [Time.singleton_class, :now, ->(_ruby, *) { Determinism.current.clock.now.getlocal }],
        [Object, :sleep, lambda do |ruby, seconds = nil|
          state = Determinism.current
          return Hooks.ruby(ruby, seconds) unless state&.actor_threads&.include?(Thread.current)
          raise ArgumentError, 'an actor cannot sleep forever in a simulation' if seconds.nil?

          state.sleeper.call(seconds)
          seconds.round
        end],
        *[Object, Kernel.singleton_class, Random.singleton_class].map { [it, :rand, ->(*a) { Hooks.rand(*a) }] },
        *%i[random_bytes gen_random random_number].map do |name|
          [SecureRandom.singleton_class, name, ->(*a) { Hooks.public_send(name, *a) }]
        end
      ].freeze

      # Puts every hook in place, and returns a proc that takes them away.
      def self.install
        put_backs = LIST.map { |owner, name, body| swap(owner, name, body) }.reverse
        -> { put_backs.each(&:call) }
      end

      def self.swap(owner, name, body)
        own = owner.method_defined?(name, false) || owner.private_method_defined?(name, false)
        ruby = owner.instance_method(name)
        was_private = owner.private_method_defined?(name)
        owner.define_method(name) { |*args, &block| body.call(ruby.bind(self), *args, &block) }
        owner.send(:private, name) if was_private
        lambda do
          own ? owner.define_method(name, ruby) : owner.send(:remove_method, name)
          owner.send(:private, name) if own && was_private
        end
      end

      # Ruby's own method, with the one argument the hook was given, or
      # none. Not ruby.call(*argument): that would spread a Range into
      # its values.
      def self.ruby(ruby, argument) = argument.nil? ? ruby.call : ruby.call(argument)

      # Kernel.rand and Random.rand take a maximum of 0 or nil to mean a
      # float; Random#rand does not.
      def self.rand(ruby, max = nil)
        random = Determinism.actor_random
        return ruby(ruby, max) unless random

        if max.nil? || max == 0 # a Range has no zero?
          random.rand
        else
          random.rand(max.is_a?(Range) ? max : max.abs)
        end
      end

      # Only on an actor's thread: other threads in the process (Rails makes
      # an id for each thread's instrumenter) would draw from the same
      # generator at times the seed does not decide.
      def self.random_bytes(ruby, size = nil)
        random = Determinism.actor_random
        random ? random.bytes(size || 16) : ruby(ruby, size)
      end

      def self.gen_random(ruby, size)
        random = Determinism.actor_random
        random ? random.bytes(size) : ruby.call(size)
      end

      def self.random_number(ruby, *)
        random = Determinism.actor_random
        random ? random.rand(*) : ruby.call(*)
      end
    end
  end
end
