# frozen_string_literal: true

require_relative 'whole_number'

# How a seeded spec picks its seeds, for any pair of settings. A module
# that extends this one names them in ONE and MANY, and its tag in TAG.
# Each spec has a default count, the number bin/check runs:
#
#   <MANY>=10000  runs seeds 1 to 10000 instead
#   <ONE>=12      runs seed 12 alone, and wins over the other
#
# A value that is not a whole number stops the run with an error. Running
# the default instead would look like a long run that found nothing.
#
# Tag each seeded example with `<TAG>: seed`. When it fails, its failure
# ends with the command that reruns that seed alone.
module SeedSettings
  def seeds(default:, env: ENV)
    count = env.key?(self::MANY) ? whole_number(env, self::MANY, minimum: 1, example: 10_000) : default
    return [whole_number(env, self::ONE, minimum: 0, example: 12)] if env.key?(self::ONE)

    (1..count).to_a
  end

  def rerun_command(seed, path) = "#{self::ONE}=#{seed} bundle exec rspec #{path}"

  # RSpec prints a failure's extra_failure_lines under its message.
  def install(config)
    settings = self
    config.after(:each, self::TAG) do |example|
      next unless example.exception

      example.metadata[:extra_failure_lines] = settings.failure_lines(example, example.metadata.fetch(settings::TAG))
    end
  end

  def failure_lines(example, seed)
    ["Seed #{seed}. Rerun it alone with: #{rerun_command(seed, example.metadata.fetch(:rerun_file_path))}"]
  end

  private

  def whole_number(env, name, minimum:, example:) = WholeNumber.read(env, name, minimum:, example:)
end

# The seeds the money property specs run.
module PropertySeeds
  ONE = 'MONEY_PROPERTY_SEED'
  MANY = 'MONEY_PROPERTY_SEEDS'
  TAG = :property_seed
  extend SeedSettings
end

RSpec.configure { |config| PropertySeeds.install(config) }
