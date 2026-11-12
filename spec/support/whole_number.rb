# frozen_string_literal: true

# Reads a test setting that must be a whole number (SeedSettings, the
# storm's knobs). Digits only, read as base 10: Integer('010') would be
# 8, and Integer('1_000'), Integer(' 10') and Integer('0x10') would pass.
module WholeNumber
  def self.read(env, name, minimum:, example:)
    value = env.fetch(name)
    number = value.match?(/\A[0-9]+\z/) ? Integer(value, 10) : nil
    return number if number && number >= minimum

    raise ArgumentError, "#{name} must be a whole number of #{minimum} or more, like #{example}; got #{value.inspect}"
  end
end
