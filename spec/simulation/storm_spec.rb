# frozen_string_literal: true

require 'rails_helper'

# The request storm (spec/concurrency/request_storm_spec.rb), run by the
# seeded scheduler: every client, the settler, the nightly jobs and the
# admin are actors, one SQL statement runs at a time, and the seed picks
# whose. So a storm that fails can be run again, step for step
# (challenge 31).
RSpec.describe Simulation::Storm, prosopite: false, server_notices: [ServerNotices::REFUSED_COMMIT] do
  include_context 'with no test transaction'
  include_context 'with a pool for a simulation', 16

  def storm(seed)
    described_class.call(seed: seed, clients: 4, seconds: 1)
  end

  it 'replays a storm exactly: the same statements in the same order, and the same answers' do
    first, second = Array.new(2) { storm(3) }
    expect(first.steps).to eq(second.steps)
    expect(first.requests).to eq(second.requests)
  end

  it 'interleaves the actors inside their transactions' do
    steps = storm(3).steps.sort_by(&:sent)
    switches = steps.each_cons(2).count { |a, b| a.actor != b.actor }
    expect(switches).to be > steps.size / 4
  end

  # bin/check runs two seeds; SIM_SEEDS runs more, and SIM_SEED replays
  # one (spec/support/simulation_seeds.rb).
  SimulationSeeds.seeds(default: 2).each do |seed|
    it "answers every request the way the API promises, and the books are right after (seed #{seed})",
       simulation_seed: seed do
      result = storm(seed)
      expect(result.requests).not_to be_empty
      expect(result.problems).to be_empty, result.problems.first(20).join("\n")
    end
  end
end
