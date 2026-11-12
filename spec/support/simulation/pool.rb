# frozen_string_literal: true

# A simulation runs every actor on a connection of its own, and the
# scheduler reads pg_locks on one more. The test pool is 2, so a group
# that runs a simulation widens it for the group and puts it back after:
#
#   include_context 'with a pool for a simulation', 40
RSpec.shared_context 'with a pool for a simulation' do |size|
  before(:all) do
    # rubocop:disable RSpec/InstanceVariable -- before(:all) has no let; the pool is process state
    @pool_before_the_simulation = ActiveRecord::Base.connection_db_config.configuration_hash
    ActiveRecord::Base.establish_connection(@pool_before_the_simulation.merge(pool: size))
  end

  after(:all) do
    ActiveRecord::Base.establish_connection(@pool_before_the_simulation)
    # rubocop:enable RSpec/InstanceVariable
  end
end
