# frozen_string_literal: true

require_relative 'property_seeds'

# The seeds the simulations run (challenge 31), set the way the money
# property specs' are (SeedSettings):
#
#   SIM_SEEDS=500  runs seeds 1 to 500
#   SIM_SEED=37    runs seed 37 alone, and replays it exactly
#
#   SIM_CLIENTS=16 SIM_SECONDS=5   a bigger simulated storm (4 and 1
#                                  unless set)
#
# A seed replays only in a storm of the same size, so the rerun command
# names the size whenever it was set.
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

  SIZE = { clients: ['SIM_CLIENTS', 4], seconds: ['SIM_SECONDS', 1] }.freeze

  def self.storm_size(env: ENV)
    SIZE.to_h do |key, (name, default)|
      [key, env.key?(name) ? WholeNumber.read(env, name, minimum: 1, example: default) : default]
    end
  end

  def self.rerun_command(seed, path, env: ENV)
    size = SIZE.values.filter_map { |name, _| "#{name}=#{env[name]} " if env.key?(name) }.join
    "#{size}#{super(seed, path)}"
  end

  # Only a failure needs its trace. RSpec keeps every example's metadata
  # until the run ends, so a run of 2000 seeds that kept every trace grew
  # past 1.7 GB.
  def self.install(config)
    super
    config.after(:each, TAG) do |example|
      example.metadata.delete(Simulation::Trace::KEY) unless example.exception
    end
  end

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
