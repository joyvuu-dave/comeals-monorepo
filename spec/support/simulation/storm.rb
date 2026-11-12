# frozen_string_literal: true

module Simulation
  # The request storm (Storm::Run) with every actor given to the seeded
  # scheduler instead of a thread of its own: each client, the settler,
  # the nightly jobs and the admin. One SQL statement runs at a time and
  # the seed picks whose, so a storm that fails can be run again step for
  # step (challenge 31).
  #
  # The run starts from the same place every time (World), and the
  # storm's clock is the simulation's clock, so "one second of storm" is
  # one second of simulated time, whatever the machine.
  class Storm
    Result = Data.define(:steps, :requests, :background, :problems)

    def self.call(**)
      new(**).call
    end

    def initialize(seed:, clients:, seconds:, start: Scheduler::START)
      @seed = seed
      @clients = clients
      @seconds = seconds
      @start = start
    end

    def call
      World.around_a_run do
        plan = World.plant(seed: @seed, start: @start) { ::Storm::Seed.plant(clients: @clients) }
        run, steps = storm(plan)
        result = run.result
        Result.new(steps: steps, requests: result.requests, background: result.background,
                   problems: problems(result) + checks(plan))
      end
    end

    private

    def storm(plan)
      starts_at = @start + 60
      scheduler = Scheduler.new(seed: @seed, start: starts_at)
      run = ::Storm::Run.new(plan: plan, transport: ::Storm::RACK_TRANSPORT, clients: @clients,
                             seconds: @seconds, seed: @seed, clock: -> { Time.now.to_f },
                             starts_at: starts_at.to_f)
      reports = collecting_reports do
        run.actors.each { |name, work| scheduler.actor(name, &work) }
        @steps = scheduler.run.steps
      end
      @reports = reports
      [run, @steps]
    end

    # Everything the app reported through Rails.error and swallowed. Only
    # a conflict may be swallowed (request_storm_spec.rb says why).
    def collecting_reports
      reports = Queue.new
      reporter = Object.new
      reporter.define_singleton_method(:report) { |error, handled:, **| reports << [error, handled] }
      Rails.error.subscribe(reporter)
      yield
      Array.new(reports.size) { reports.pop }
    ensure
      Rails.error.unsubscribe(reporter)
    end

    def problems(result)
      result.requests.filter_map { |e| e.problem && "client #{e.client} ##{e.n} #{e.action}: #{e.problem}" } +
        result.problems +
        @reports.filter_map do |error, handled|
          next if !handled || error.is_a?(ActiveRecord::TransactionRollbackError)

          "reported and swallowed: #{error.class}: #{error.message[0, 300]}"
        end.uniq
    end

    # The checks read the calendar and the community's today, so they run
    # on the simulation's clock too, just after the storm ended.
    def checks(plan)
      Determinism.with(seed: @seed, start: @start + 60 + @seconds + 60) do
        ::Storm::Checks.call(plan: plan, transport: ::Storm::RACK_TRANSPORT)
      end
    end
  end
end
