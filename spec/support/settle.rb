# frozen_string_literal: true

# The one way specs run a settlement.
#
# Every spec that needs a settled period calls settle!, not Settlement
# directly. This was the seam for moving the settlement pipeline out of the
# Reconciliation callback (approach D, 2026-08-23): the line below changed
# and the specs that call it did not, which is how
# spec/services/settlement_contract_spec.rb proved the move broke nothing.
module Settle
  # The default cutoff is the latest one allowed today, 14 days back (ADR
  # 0011 rule 2), which is also the newest date a meal made with no date
  # gets (DefaultMealDate).
  def settle!(cutoff: Reconciliation.latest_cutoff(Community.instance.today))
    Settlement.run!(cutoff: cutoff)
  end

  # What the Create button on the admin settlement preview sends: the
  # cutoff, and the fingerprint of the preview for it (ADR 0011 rule 4).
  def admin_settle_params(cutoff)
    { reconciliation: { end_date: cutoff }, fingerprint: Settlement.preview(cutoff: cutoff).fingerprint }
  end

  # A settlement made the way every one was before ADR 0011 rule 3
  # (2026-10-13): a dinner where someone was charged and a cook's cost was
  # blank was settled, and the blank cost was locked at $0. The old
  # settlements in production hold such dinners, so the specs of the data
  # migrations and the corrections that fix them build one this way. Only
  # the choice of meals is the old one (Meal.settleable_by without its
  # clause for blank costs); the rest is the real settlement.
  def settle_as_before_rule_3!(cutoff:)
    allow(Meal).to receive(:settleable_by).and_invoke(lambda do |until_date, today: Community.instance.today|
      Meal.unreconciled.joins(:bills).where(date: ..until_date).where(date: ...today)
          .where(Meal.someone_to_charge.or(Meal.a_receipt_with_money.not)).distinct
    end)
    settle!(cutoff: cutoff)
  ensure
    allow(Meal).to receive(:settleable_by).and_call_original
  end
end

RSpec.configure do |config|
  config.include Settle
end
