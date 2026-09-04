# typed: strict
# frozen_string_literal: true

# Recomputes every resident's running balance from source data and stores
# it in resident_balances, the one cache on the money path.
#
# The running balance is what a resident owes or is owed for the meals not
# yet settled. It is derived, never a source of truth: this can run at any
# time and always produces the same answer for the same source rows.
#
# Runs nightly (rake billing:recalculate) and right after every settlement
# (SettleAndNotify), because a settlement moves meals out of the running
# balance and the number on the admin screens should follow at once.
class BalanceRecalculation
  extend T::Sig

  sig { params(community: Community).returns(Integer) }
  def self.call(community: Community.instance)
    new(community).call
  end

  sig { params(community: Community).void }
  def initialize(community)
    @community = community
  end

  # Returns the number of balances written.
  sig { returns(Integer) }
  def call
    # Read every source record inside one snapshot so all five queries
    # (meals, three preloads, residents) see one instant. Unreconciled meals
    # are mutable: without this, a meal edit committing between two of the
    # reads yields per-meal financials that match no real state of the
    # ledger. SnapshotRead opens the transaction SERIALIZABLE READ ONLY
    # DEFERRABLE, which cannot abort with a serialization failure and so
    # still needs no retry. See app/services/snapshot_read.rb.
    unreconciled_meals, resident_ids = SnapshotRead.call do
      # Batch-load all unreconciled meals with their financial associations
      # (4 queries). Uses preload (not includes) to guarantee separate IN(?)
      # queries. The joins(:bills).distinct excludes meals without bills —
      # their unit_cost is 0, so they contribute nothing to any balance.
      #
      # MealLedger below runs no queries of its own, which is what keeps the
      # whole computation inside this snapshot.
      meals = @community.meals.unreconciled.with_attendees
                        .joins(:bills).distinct
                        .preload(:bills, :meal_residents, :guests).to_a
      [meals, @community.residents.pluck(:id)]
    end

    # The arithmetic is MealLedger's, shared with Reconciliation#settlement_balances
    # so the running balance and the settled balance cannot follow different
    # rules (0 queries).
    balances = MealLedger.new(unreconciled_meals).balances(resident_ids)

    # Persist balances via upsert, outside the read transaction (safe if two
    # runs overlap: each computes from its own consistent snapshot, the
    # single INSERT ... ON CONFLICT UPDATE statement is atomic, and the next
    # daily run corrects whichever result lost the last-writer race).
    now = Time.current
    rows = resident_ids.map do |resident_id|
      { resident_id: resident_id, amount: balances.fetch(resident_id), created_at: now, updated_at: now }
    end
    ResidentBalance.upsert_all(rows, unique_by: :resident_id, update_only: %i[amount]) if rows.any?
    rows.size
  end
end
