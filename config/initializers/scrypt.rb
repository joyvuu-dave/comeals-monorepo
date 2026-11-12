# typed: false
# frozen_string_literal: true

# The SCrypt cost for a password (Resident, CommonHouseLogin): the
# smallest one in the test environment, so the suite runs fast, and
# everywhere else none set, so SCrypt measures the machine before each
# hash and picks the cost that takes about 0.2 seconds there (its
# max_time default). A method, so a spec can ask for the value of another
# environment (spec/config/initializers/scrypt_spec.rb), as with
# DevisePasswordStretches.
#
# The cost string is N$r$p$ in hex: N = 16, r = 8, p = 1. Before
# 2026-11-12 the test environment measured the machine too: about 0.16
# seconds for every resident a spec made, and a cost that depended on
# how busy the machine was.
module ScryptCost
  TEST = '10$8$1$'

  def self.for(env)
    env.test? ? TEST : nil
  end
end

SCrypt::Engine.calibrated_cost = ScryptCost.for(Rails.env)
