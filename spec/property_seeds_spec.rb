# frozen_string_literal: true

require 'rails_helper'

# spec/support/property_seeds.rb picks the seeds the money property specs
# run, and adds the command that reruns a failed seed to its failure.
RSpec.describe PropertySeeds do
  describe '.seeds' do
    it 'gives 1 up to the default when neither setting is there' do
      expect(described_class.seeds(default: 5, env: {})).to eq([1, 2, 3, 4, 5])
    end

    it 'gives 1 up to MONEY_PROPERTY_SEEDS when it is set' do
      expect(described_class.seeds(default: 5, env: { 'MONEY_PROPERTY_SEEDS' => '8' })).to eq((1..8).to_a)
    end

    it 'can run fewer seeds than the default' do
      expect(described_class.seeds(default: 5, env: { 'MONEY_PROPERTY_SEEDS' => '2' })).to eq([1, 2])
    end

    it 'gives the one seed in MONEY_PROPERTY_SEED' do
      expect(described_class.seeds(default: 5, env: { 'MONEY_PROPERTY_SEED' => '4321' })).to eq([4321])
    end

    it 'takes seed 0 as one seed, since Random.new(0) is a seed like any other' do
      expect(described_class.seeds(default: 5, env: { 'MONEY_PROPERTY_SEED' => '0' })).to eq([0])
    end

    it 'gives the one seed when both settings are there' do
      env = { 'MONEY_PROPERTY_SEED' => '17', 'MONEY_PROPERTY_SEEDS' => '10000' }
      expect(described_class.seeds(default: 5, env: env)).to eq([17])
    end

    # A typo must not run the default and pass, which would look like a
    # long run that found nothing.
    ['0', '-3', '2.5', 'ten', '', ' 10', '1e4', '10_000', '0x10'].each do |value|
      it "refuses MONEY_PROPERTY_SEEDS=#{value.inspect}" do
        expect { described_class.seeds(default: 5, env: { 'MONEY_PROPERTY_SEEDS' => value }) }
          .to raise_error(ArgumentError,
                          "MONEY_PROPERTY_SEEDS must be a whole number of 1 or more, like 10000; got #{value.inspect}")
      end
    end

    ['-3', '2.5', 'seven', '', '0x10'].each do |value|
      it "refuses MONEY_PROPERTY_SEED=#{value.inspect}" do
        expect { described_class.seeds(default: 5, env: { 'MONEY_PROPERTY_SEED' => value }) }
          .to raise_error(ArgumentError,
                          "MONEY_PROPERTY_SEED must be a whole number of 0 or more, like 12; got #{value.inspect}")
      end
    end

    # Integer('010') is 8 in Ruby. A seed written with a leading zero must
    # still mean the number a person reads.
    it 'reads a leading zero as base 10' do
      expect(described_class.seeds(default: 5, env: { 'MONEY_PROPERTY_SEED' => '010' })).to eq([10])
    end

    it 'checks MONEY_PROPERTY_SEEDS even when MONEY_PROPERTY_SEED wins' do
      env = { 'MONEY_PROPERTY_SEED' => '17', 'MONEY_PROPERTY_SEEDS' => 'many' }
      expect { described_class.seeds(default: 5, env: env) }.to raise_error(ArgumentError, /MONEY_PROPERTY_SEEDS/)
    end
  end

  describe '.rerun_command' do
    it 'names the seed and the file' do
      expect(described_class.rerun_command(42, './spec/services/x_spec.rb'))
        .to eq('MONEY_PROPERTY_SEED=42 bundle exec rspec ./spec/services/x_spec.rb')
    end
  end

  describe 'a failing example tagged with its seed' do
    # Runs one example group in a fresh RSpec, with only this helper's hook,
    # and returns its one example.
    def run_alone(&)
      RSpec::Core::Sandbox.sandboxed do |config|
        described_class.install(config)
        group = RSpec.describe('a property', &)
        group.run(RSpec::Core::NullReporter)
        return group.examples.first
      end
    end

    it 'prints the seed and the command that reruns it' do
      example = run_alone { it('holds for ledger 9', property_seed: 9) { expect(1 + 1).to eq(3) } }

      expect(example.exception).to be_a(RSpec::Expectations::ExpectationNotMetError)
      expect(example.metadata[:extra_failure_lines]).to eq(
        ["Seed 9. Rerun it alone with: #{described_class.rerun_command(9, example.metadata[:rerun_file_path])}"]
      )
    end

    it 'adds nothing to an example that passes' do
      example = run_alone { it('holds for ledger 9', property_seed: 9) { expect(1 + 1).to eq(2) } }

      expect(example.exception).to be_nil
      expect(example.metadata[:extra_failure_lines]).to be_nil
    end

    it 'adds nothing to an example with no seed' do
      example = run_alone { it('fails') { expect(1 + 1).to eq(3) } }

      expect(example.exception).not_to be_nil
      expect(example.metadata[:extra_failure_lines]).to be_nil
    end
  end
end
