# frozen_string_literal: true

module Simulation
  # The steps of the scheduler's last run in the running example, kept in
  # its metadata, so a failure can print them (SimulationSeeds).
  module Trace
    KEY = :simulation_steps

    def self.keep(steps)
      RSpec.current_example&.metadata&.store(KEY, steps)
    end

    # One line per statement, in the order they were sent:
    #   sent, actor, SQL, binds (if any), outcome, and whether it waited.
    # sent counts every turn the scheduler gave. A turn that ran no
    # statement (an actor's start, its wake after a sleep) leaves a gap.
    def self.lines(steps)
      steps.sort_by(&:sent).map do |step|
        line = "#{step.sent.to_s.rjust(7)} #{step.actor}  #{step.sql}"
        line << "  #{step.binds.inspect}" unless step.binds.empty?
        line << "  -> #{step.outcome}"
        line << '  (waited for a lock)' if step.waited
        line
      end
    end
  end
end
