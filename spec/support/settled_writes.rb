# frozen_string_literal: true

# How a spec writes a line item or a settled balance by hand.
#
# The database refuses an insert into meal_charges or
# reconciliation_balances unless the settlement of that row's
# reconciliation is writing it, or the repair bypass is on (migration
# 20261009120000). So a spec that needs such a row says which of the two
# it is acting as:
#
#   SettledWrites.as_settlement_of(reconciliation) { ... }
#     writes as that reconciliation's settlement, with the setting that
#     Settlement#write_ledger! sets (Settlement::SETTLING_SETTING).
#   SettledWrites.with_repair_bypass { ... }
#     writes as a repair, with comeals.allow_settled_writes on
#     (docs/runbooks/settled-data-repair.md).
#
# Both are also included in every example group, so an example can call
# them without the module name.
#
# The block runs in its own savepoint, and the setting is turned off again
# when the block ends. A plain SET LOCAL inside an example's transaction
# would stay on until the example ends, and let every later write through.
module SettledWrites
  module_function

  def as_settlement_of(reconciliation, &)
    with_local_setting(Settlement::SETTLING_SETTING, reconciliation.id.to_s, &)
  end

  def with_repair_bypass(&)
    with_local_setting('comeals.allow_settled_writes', 'on', &)
  end

  def with_local_setting(name, value)
    ActiveRecord::Base.transaction(requires_new: true) do
      set_local_setting(name, value)
      result = yield
      set_local_setting(name, '')
      result
    end
  end

  def set_local_setting(name, value)
    ActiveRecord::Base.connection.execute(
      ActiveRecord::Base.sanitize_sql_array(['SELECT set_config(?, ?, true)', name, value])
    )
  end
end

RSpec.configure do |config|
  config.include SettledWrites
end
