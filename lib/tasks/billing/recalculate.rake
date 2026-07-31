# frozen_string_literal: true

namespace :billing do
  desc 'Recalculate all resident balances from source records. Safe to run at any time.'
  task recalculate: :environment do
    Healthcheck.monitor('billing-recalculate') do
      start_time = Time.current

      community = Community.instance

      # Read every source record inside one snapshot so all five queries
      # (meals, three preloads, residents) see one instant. Unreconciled meals
      # are mutable: without this, a meal edit committing between two of the
      # reads yields per-meal financials that match no real state of the
      # ledger. SnapshotRead opens the transaction SERIALIZABLE READ ONLY
      # DEFERRABLE, which cannot abort with a serialization failure and so
      # still needs no retry. See app/services/snapshot_read.rb.
      unreconciled_meals = nil
      resident_ids = nil
      SnapshotRead.call do
        # Batch-load all unreconciled meals with their financial associations (4 queries).
        # Uses preload (not includes) to guarantee separate IN(?) queries.
        # The joins(:bills).distinct excludes meals without bills — their unit_cost
        # is 0, so they contribute nothing to any resident's balance.
        #
        # MealLedger below runs no queries of its own, which is what keeps the
        # whole computation inside this snapshot.
        unreconciled_meals = community.meals.unreconciled.with_attendees
                                      .joins(:bills).distinct
                                      .preload(:bills, :meal_residents, :guests).to_a
        resident_ids = community.residents.pluck(:id)
      end

      # The arithmetic is MealLedger's, shared with
      # Reconciliation#settlement_balances so the running balance and the
      # settled balance cannot follow different rules (0 queries).
      balances = MealLedger.new(unreconciled_meals).balances(resident_ids)

      # Persist balances via upsert, outside the read transaction (safe if two
      # rake runs overlap: each computes from its own consistent snapshot, the
      # single INSERT ... ON CONFLICT UPDATE statement is atomic, and the next
      # daily run corrects whichever result lost the last-writer race).
      # Batches all residents into a single INSERT ... ON CONFLICT UPDATE query.
      now = Time.current
      rows = resident_ids.map do |resident_id|
        { resident_id: resident_id, amount: balances[resident_id], created_at: now, updated_at: now }
      end

      ResidentBalance.upsert_all(rows, unique_by: :resident_id, update_only: %i[amount]) if rows.any?

      total_time = Time.current - start_time
      Rails.logger.info("billing:recalculate completed in #{total_time.round(2)}s")
    end
  end
end
