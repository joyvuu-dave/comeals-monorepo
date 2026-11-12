# frozen_string_literal: true

require 'rails_helper'
require 'rspec/core/sandbox'

# spec/support/simulation_seeds.rb picks the seeds the simulations run
# (challenge 31), the same way PropertySeeds does for the money property
# specs, and a failed seed leaves its trace: the command that reruns it,
# and every statement the run sent, in a file.
RSpec.describe SimulationSeeds do
  describe '.seeds' do
    it 'gives 1 up to the default, 1 up to SIM_SEEDS, or the one SIM_SEED' do
      expect(described_class.seeds(default: 3, env: {})).to eq([1, 2, 3])
      expect(described_class.seeds(default: 3, env: { 'SIM_SEEDS' => '5' })).to eq([1, 2, 3, 4, 5])
      expect(described_class.seeds(default: 3, env: { 'SIM_SEED' => '77', 'SIM_SEEDS' => '5' })).to eq([77])
    end

    it 'refuses a setting that is not a whole number' do
      expect { described_class.seeds(default: 3, env: { 'SIM_SEEDS' => 'lots' }) }
        .to raise_error(ArgumentError, 'SIM_SEEDS must be a whole number of 1 or more, like 10000; got "lots"')
    end
  end

  it 'names the seed and the file in the rerun command' do
    expect(described_class.rerun_command(42, './spec/simulation/x_spec.rb', env: {}))
      .to eq('SIM_SEED=42 bundle exec rspec ./spec/simulation/x_spec.rb')
  end

  # A seed replays only in a storm of the same size.
  it 'names the storm size in the rerun command when it was set' do
    env = { 'SIM_CLIENTS' => '8', 'SIM_SECONDS' => '3' }
    expect(described_class.rerun_command(42, './spec/simulation/x_spec.rb', env: env))
      .to eq('SIM_CLIENTS=8 SIM_SECONDS=3 SIM_SEED=42 bundle exec rspec ./spec/simulation/x_spec.rb')
  end

  describe '.storm_size' do
    it 'is 4 clients for 1 second unless set' do
      expect(described_class.storm_size(env: {})).to eq(clients: 4, seconds: 1)
    end

    it 'reads SIM_CLIENTS and SIM_SECONDS' do
      expect(described_class.storm_size(env: { 'SIM_CLIENTS' => '16', 'SIM_SECONDS' => '05' }))
        .to eq(clients: 16, seconds: 5)
    end

    it 'refuses a size that is not a whole number of 1 or more' do
      expect { described_class.storm_size(env: { 'SIM_CLIENTS' => '0' }) }
        .to raise_error(ArgumentError, 'SIM_CLIENTS must be a whole number of 1 or more, like 4; got "0"')
    end
  end

  describe 'a failing example tagged with its seed' do
    let(:steps) do
      [Simulation::Step.new(sent: 2, actor: :b, sql: 'UPDATE t SET v = 1', binds: [], outcome: 1, waited: true),
       Simulation::Step.new(sent: 1, actor: :a, sql: 'SELECT v FROM t WHERE id = $1', binds: [7], outcome: 1,
                            waited: false)] +
        (3..40).map do |sent|
          Simulation::Step.new(sent: sent, actor: :a, sql: "SELECT #{sent}", binds: [], outcome: 1, waited: false)
        end
    end

    def run_alone(&)
      RSpec::Core::Sandbox.sandboxed do |config|
        described_class.install(config)
        group = RSpec.describe('a simulation', &)
        group.run(RSpec::Core::NullReporter)
        return group.examples.first
      end
    end

    it 'prints the rerun command, writes every step to a file, and prints the last ones' do
      steps = self.steps
      example = run_alone do
        it('holds for seed 9', simulation_seed: 9) do
          Simulation::Trace.keep(steps)
          expect(1 + 1).to eq(3)
        end
      end

      lines = example.metadata[:extra_failure_lines]
      path = Rails.root.join('tmp/simulation/a_simulation_holds_for_seed_9.txt')
      expect(lines.first).to eq(
        "Seed 9. Rerun it alone with: #{described_class.rerun_command(9, example.metadata[:rerun_file_path])}"
      )
      expect(lines).to include("All 40 statements of the run, in the order they were sent: #{path}")
      expect(lines.last(2)).to eq(['     39 a  SELECT 39  -> 1', '     40 a  SELECT 40  -> 1'])
      expect(File.readlines(path, chomp: true).first(2)).to eq(
        ['      1 a  SELECT v FROM t WHERE id = $1  [7]  -> 1',
         '      2 b  UPDATE t SET v = 1  -> 1  (waited for a lock)']
      )
    ensure
      FileUtils.rm_f(path) if path
    end

    it 'prints only the rerun command when the example kept no trace' do
      example = run_alone { it('holds for seed 9', simulation_seed: 9) { expect(1 + 1).to eq(3) } }

      expect(example.metadata[:extra_failure_lines].size).to eq(1)
    end

    it 'adds nothing to an example that passes' do
      steps = self.steps
      example = run_alone do
        it('holds', simulation_seed: 9) { expect(Simulation::Trace.keep(steps)).to eq(steps) }
      end

      expect(example.metadata[:extra_failure_lines]).to be_nil
    end

    # RSpec keeps every example's metadata until the run ends. A run of
    # 2000 seeds kept 2000 traces and grew past 1.7 GB.
    it 'drops the trace of an example that passes' do
      steps = self.steps
      example = run_alone do
        it('holds', simulation_seed: 9) { expect(Simulation::Trace.keep(steps)).to eq(steps) }
      end

      expect(example.metadata).not_to have_key(Simulation::Trace::KEY)
    end
  end
end
