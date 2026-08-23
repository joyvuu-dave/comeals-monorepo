# frozen_string_literal: true

# The one way specs run a settlement.
#
# Every spec that needs a settled period should call settle!, not
# Reconciliation.create! directly. This is the seam for moving the
# settlement pipeline out of the Reconciliation callback (approach D,
# 2026-08-23): when the pipeline becomes Settlement.run!(cutoff:), this
# method changes and the specs that use it do not. A spec that survives
# the refactor unchanged is the only kind that can prove the refactor
# broke nothing, which is why spec/services/settlement_contract_spec.rb
# uses nothing else.
module Settle
  def settle!(community, cutoff: Date.yesterday)
    Reconciliation.create!(community: community, end_date: cutoff)
  end
end

RSpec.configure do |config|
  config.include Settle
end
