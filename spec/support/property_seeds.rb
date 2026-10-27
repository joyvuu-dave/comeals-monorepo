# frozen_string_literal: true

# The seeds the money property specs run. Each spec has a default count,
# the number bin/check runs. Two settings change it:
#
#   MONEY_PROPERTY_SEEDS=10000  runs seeds 1 to 10000 instead
#   MONEY_PROPERTY_SEED=12      runs seed 12 alone, and wins over the other
#
# A value that is not a whole number stops the run with an error. Running
# the default instead would look like a long run that found nothing.
#
# Tag each seeded example with `property_seed: seed`. When it fails, its
# failure ends with the command that reruns that seed alone.
module PropertySeeds
  ONE = 'MONEY_PROPERTY_SEED'
  MANY = 'MONEY_PROPERTY_SEEDS'

  def self.seeds(default:, env: ENV)
    count = env.key?(MANY) ? whole_number(env, MANY, minimum: 1, example: 10_000) : default
    return [whole_number(env, ONE, minimum: 0, example: 12)] if env.key?(ONE)

    (1..count).to_a
  end

  def self.rerun_command(seed, path) = "#{ONE}=#{seed} bundle exec rspec #{path}"

  # Digits only, read as base 10: Integer('010') would be 8, and
  # Integer('1_000') and Integer(' 10') would pass.
  def self.whole_number(env, name, minimum:, example:)
    value = env.fetch(name)
    number = value.match?(/\A[0-9]+\z/) ? Integer(value, 10) : nil
    return number if number && number >= minimum

    raise ArgumentError, "#{name} must be a whole number of #{minimum} or more, like #{example}; got #{value.inspect}"
  end
  private_class_method :whole_number

  # RSpec prints a failure's extra_failure_lines under its message.
  def self.install(config)
    config.after(:each, :property_seed) do |example|
      next unless example.exception

      seed = example.metadata.fetch(:property_seed)
      command = PropertySeeds.rerun_command(seed, example.metadata.fetch(:rerun_file_path))
      example.metadata[:extra_failure_lines] = ["Seed #{seed}. Rerun it alone with: #{command}"]
    end
  end
end

RSpec.configure { |config| PropertySeeds.install(config) }
