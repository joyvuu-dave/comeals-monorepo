# frozen_string_literal: true

# The one way specs run a settlement.
#
# Every spec that needs a settled period calls settle!, not Settlement
# directly. This was the seam for moving the settlement pipeline out of the
# Reconciliation callback (approach D, 2026-08-23): the line below changed
# and the specs that call it did not, which is how
# spec/services/settlement_contract_spec.rb proved the move broke nothing.
module Settle
  def settle!(community, cutoff: Date.yesterday)
    Settlement.run!(cutoff: cutoff, community: community)
  end
end

RSpec.configure do |config|
  config.include Settle
end
