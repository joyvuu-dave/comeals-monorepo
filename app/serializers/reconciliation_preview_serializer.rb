# frozen_string_literal: true

# The JSON for GET /api/v1/reconciliations/preview: what a settlement at the
# given cutoff would claim and store, plus data-quality warnings. Built
# from a Settlement::Preview, not from a saved record — nothing here has
# been written.
#
# Money crosses the wire as strings (a BigDecimal encodes as a string under
# the Oj Rails-mode encoder, see config/initializers/alba.rb). unit_cost is
# a full-precision intermediate; the balances are rounded to cents by the
# same largest-remainder step a real settlement uses. The sign carries the
# direction: positive means the community owes the resident.
#
# Contract and design notes: COLLECT_APP.md.
class ReconciliationPreviewSerializer
  include Alba::Resource

  attribute :cutoff_date do |preview|
    preview.cutoff.iso8601
  end

  attribute :generated_at do |_preview|
    Time.current.utc.iso8601
  end

  attribute :summary do |preview|
    meals = preview.meals
    balances = preview.resident_balances.reject { |_, amount| amount.zero? }
    {
      meal_count: meals.size,
      total_cost: meals.sum(BigDecimal('0')) { |meal| preview.meal_summary(meal).total_cost },
      earliest_meal_date: meals.first&.date&.iso8601,
      latest_meal_date: meals.last&.date&.iso8601,
      residents_affected: balances.size,
      units_affected: Resident.where(id: balances.keys).distinct.count(:unit_id)
    }
  end

  attribute :meals do |preview|
    preview.meals.map do |meal|
      summary = preview.meal_summary(meal)
      total_multiplier = meal.meal_residents.sum(&:multiplier) + meal.guests.sum(&:multiplier)
      {
        id: meal.id,
        date: meal.date.iso8601,
        description: meal.description,
        total_cost: summary.total_cost,
        effective_cost: summary.effective_cost,
        capped: meal.capped?,
        subsidized: summary.subsidized,
        total_multiplier: total_multiplier,
        unit_cost: summary.unit_cost,
        attendee_count: meal.meal_residents.size,
        guest_count: meal.guests.size,
        cooks: meal.bills.map do |bill|
          { resident_id: bill.resident_id, name: bill.resident.name, bill_amount: bill.amount, no_cost: bill.no_cost }
        end
      }
    end
  end

  # Every resident with a non-zero balance, and every unit, including
  # units whose residents all come out at zero (the reconciler's mental
  # model is per unit, and a unit at $0.00 is a fact worth showing).
  # resident_count is how many of the unit's residents have a non-zero
  # balance.
  attribute :balances do |preview|
    nonzero = preview.resident_balances.reject { |_, amount| amount.zero? }
    residents = Resident.where(id: nonzero.keys).includes(:unit).index_by(&:id)
    {
      residents: nonzero.keys.sort.map do |resident_id|
        resident = residents.fetch(resident_id)
        { resident_id: resident_id, name: resident.name, unit_id: resident.unit_id,
          unit_name: resident.unit.name, amount: nonzero[resident_id] }
      end,
      units: Unit.order(:name).map do |unit|
        in_unit = residents.values.select { |resident| resident.unit_id == unit.id }
        { unit_id: unit.id, unit_name: unit.name,
          amount: in_unit.sum(BigDecimal('0')) { |resident| nonzero[resident.id] },
          resident_count: in_unit.size }
      end
    }
  end

  # A warning's meal_id may name a meal that is not in `meals`: the
  # attendance-without-bill warning is about meals the settlement leaves
  # behind, which by definition are not in the list it would claim.
  attribute :warnings do |preview|
    ReconciliationWarnings.for(preview.meals, skipped: preview.skipped_meals)
  end
end
