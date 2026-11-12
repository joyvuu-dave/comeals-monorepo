# frozen_string_literal: true

require_relative 'property_seeds'

# The seeds the simulations run (challenge 31), set the way the money
# property specs' are (SeedSettings):
#
#   SIM_SEEDS=500  runs seeds 1 to 500
#   SIM_SEED=37    runs seed 37 alone, and replays it exactly
#
# A failed seed also leaves the trace of its last scheduler run: every
# statement in a file under tmp/simulation, and the last few under the
# failure, so the end of the run can be read without opening the file.
module SimulationSeeds
  ONE = 'SIM_SEED'
  MANY = 'SIM_SEEDS'
  TAG = :simulation_seed
  LAST_STEPS = 20
  extend SeedSettings

  def self.failure_lines(example, seed)
    lines = super
    steps = example.metadata[Simulation::Trace::KEY]
    return lines unless steps

    trace = Simulation::Trace.lines(steps)
    path = Rails.root.join('tmp/simulation', "#{example.full_description.parameterize(separator: '_')}.txt")
    FileUtils.mkdir_p(path.dirname)
    File.write(path, trace.join("\n") << "\n")
    lines + ["All #{trace.size} statements of the run, in the order they were sent: #{path}",
             "The last #{[LAST_STEPS, trace.size].min}:", *trace.last(LAST_STEPS)]
  end
end

RSpec.configure { |config| SimulationSeeds.install(config) }
