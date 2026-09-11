# frozen_string_literal: true

module Storm
  # The storm's settings, from the environment, with a default. Read by
  # the RSpec storm at load time (the pool is sized in before(:all), which
  # has no let) and by the rake task.
  def self.knob(name, default)
    Integer(ENV.fetch("STORM_#{name.to_s.upcase}", default))
  end
end
