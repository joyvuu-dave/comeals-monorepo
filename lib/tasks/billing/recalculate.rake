# frozen_string_literal: true

namespace :billing do
  desc 'Recalculate all resident balances from source records. Safe to run at any time.'
  task recalculate: :environment do
    start_time = Time.current

    community = Community.instance

    # Batch-load all unreconciled meals with their financial associations (4 queries).
    # Uses preload (not includes) to guarantee separate IN(?) queries.
    # The joins(:bills).distinct excludes meals without bills — their unit_cost
    # is 0, so they contribute nothing to any resident's balance.
    unreconciled_meals = community.meals.unreconciled.with_attendees
                                  .joins(:bills).distinct
                                  .preload(:bills, :meal_residents, :guests).to_a

    # Precompute per-meal financials from in-memory data (0 queries).
    # Uses block-form .sum(&:field) which invokes Enumerable#sum on the
    # loaded array. The column-form .sum(:field) always fires SQL.
    # Stores total_cost and effective_cost so the credit calculation can
    # apply proportional capping for subsidized meals.
    meal_financials = {}
    unreconciled_meals.each do |meal|
      total_mult = meal.meal_residents.sum(&:multiplier) + meal.guests.sum(&:multiplier)

      if total_mult.zero?
        zero = BigDecimal('0')
        meal_financials[meal.id] = { unit_cost: zero, total_cost: zero, effective_cost: zero }
        next
      end

      total_cost = meal.bills.reject(&:no_cost).sum(BigDecimal('0'), &:amount)
      effective_cost = total_cost
      if meal.capped?
        max_cost = meal.cap * total_mult
        effective_cost = max_cost if total_cost > max_cost
      end

      meal_financials[meal.id] = {
        unit_cost: effective_cost / total_mult, total_cost: total_cost, effective_cost: effective_cost
      }
    end

    # Accumulate credits, debits, and guest debits from in-memory data (0 queries).
    # Credits use the proportional capped amount for subsidized meals.
    credits = Hash.new(BigDecimal('0'))
    debits = Hash.new(BigDecimal('0'))
    guest_debits = Hash.new(BigDecimal('0'))

    unreconciled_meals.each do |meal|
      mf = meal_financials[meal.id]

      meal.bills.each do |b|
        next if b.no_cost

        credit = if mf[:total_cost].zero?
                   BigDecimal('0')
                 elsif mf[:effective_cost] < mf[:total_cost]
                   (b.amount / mf[:total_cost]) * mf[:effective_cost]
                 else
                   b.amount
                 end
        credits[b.resident_id] += credit
      end

      meal.meal_residents.each { |mr| debits[mr.resident_id] += mf[:unit_cost] * mr.multiplier }
      meal.guests.each { |g| guest_debits[g.resident_id] += mf[:unit_cost] * g.multiplier }
    end

    # Persist balances via upsert (idempotent — safe if two rake runs overlap,
    # because both compute the same deterministic result from immutable source data).
    # Batches all residents into a single INSERT ... ON CONFLICT UPDATE query.
    now = Time.current
    rows = community.residents.pluck(:id).map do |resident_id|
      balance = credits[resident_id] - debits[resident_id] - guest_debits[resident_id]
      { resident_id: resident_id, amount: balance, created_at: now, updated_at: now }
    end

    ResidentBalance.upsert_all(rows, unique_by: :resident_id, update_only: %i[amount]) if rows.any?

    total_time = Time.current - start_time
    Rails.logger.info("billing:recalculate completed in #{total_time.round(2)}s")
  end
end
