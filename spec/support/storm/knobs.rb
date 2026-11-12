# frozen_string_literal: true

require_relative '../whole_number'

module Storm
  # The storm's settings, from the environment, with a default. Read by
  # the RSpec storm at load time (the pool is sized in before(:all), which
  # has no let) and by the rake task.
  #
  # Read the way the seed settings are (WholeNumber), so STORM_SEED=010
  # is seed 10. Until 2026-11-12 it was Integer(), which read it as 8.
  def self.knob(name, default, env: ENV)
    setting = "STORM_#{name.to_s.upcase}"
    return default unless env.key?(setting)

    WholeNumber.read(env, setting, minimum: name == :seed ? 0 : 1, example: default)
  end
end
