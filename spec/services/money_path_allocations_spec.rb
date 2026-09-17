# frozen_string_literal: true

require 'rails_helper'

# How many objects the money path allocates, pinned. A timing pin would
# fail on a slow CI runner and pass on a fast laptop; an allocation count
# is the same everywhere for the same Ruby, so it can hold in CI. Only
# pure Ruby is pinned here (no request, no serializer): a count that
# runs through Rails would move on every gem update.
#
# The budgets are about one and a half times what was measured on
# 2026-09-17 (Ruby 4.0.6): 2,487 for the ledger and 1,961 for the
# allocation. A Ruby upgrade may move them a little; a change that
# doubles them is a loop that builds something per line that it could
# build once.
#
# The ledger measured 1,646 on 2026-09-15, before it allocated shares at
# the ledger grain (ADR 0008). The rise is per meal, not per line: the
# ordered list of eaters, the shares and the dropped remainders of each
# split. A line itself is still one struct, its keyword hash and one
# BigDecimal.
RSpec.describe 'what the money path allocates' do # rubocop:disable RSpec/DescribeClass -- a budget for two classes at once, not the behaviour of either
  # Seed 11 is the largest ledger the seeds 1..30 give: 26 meals, 221
  # lines, up to 30 residents.
  let(:meals) { RandomLedger.meals(11) }

  it 'builds the lines of a 26-meal ledger in under 3,700 objects' do
    ledger = MealLedger.new(meals)

    report = MemoryProfiler.report { ledger.lines }

    expect(ledger.lines.size).to eq(221)
    expect(report.total_allocated).to be <= 3_700
  end

  it 'rounds 30 balances to cents in under 3,000 objects' do
    balances = MealLedger.new(meals).balances(RandomLedger::RESIDENTS)

    report = MemoryProfiler.report { Settlement.allocate_to_cents(balances) }

    expect(report.total_allocated).to be <= 3_000
  end

  it 'keeps nothing alive after the lines are built, beyond the lines themselves' do
    ledger = MealLedger.new(meals)

    report = MemoryProfiler.report { ledger.lines }

    # Each line is one struct with a few boxed values (measured: under 3
    # objects per line); anything far past that is a cache that outlives
    # its use.
    expect(report.total_retained).to be <= ledger.lines.size * 4
  end
end
