# frozen_string_literal: true

# == Schema Information
#
# Table name: reconciliations
#
#  id           :bigint           not null, primary key
#  date         :date             not null
#  end_date     :date             not null
#  start_date   :date             not null
#  created_at   :datetime         not null
#  updated_at   :datetime         not null
#  community_id :bigint           not null
#
# Indexes
#
#  index_reconciliations_on_community_id  (community_id)
#
# Foreign Keys
#
#  fk_rails_...  (community_id => communities.id)
#
class Reconciliation < ApplicationRecord
  # Ransack allowlists for ActiveAdmin sorting
  def self.ransackable_attributes(_auth_object = nil)
    %w[id community_id date end_date start_date created_at updated_at]
  end

  has_many :meals, dependent: :nullify
  has_many :bills, through: :meals
  has_many :cooks, through: :bills, source: :resident
  has_many :reconciliation_balances, dependent: :destroy
  belongs_to :community

  validates :start_date, presence: true
  validates :end_date, presence: true
  validate :start_date_not_after_end_date

  before_validation :set_date
  after_create :finalize

  def number_of_meals
    meals.count
  end

  def unique_cooks
    cooks.uniq
  end

  # Assigns unreconciled meals (with at least one bill) within the date range.
  def assign_meals
    meal_ids = Meal.unreconciled
                   .joins(:bills)
                   .where(date: start_date..end_date)
                   .distinct
                   .pluck(:id)
    Meal.where(id: meal_ids).update_all(reconciliation_id: id)
  end

  # Compute final settlement balances for this reconciliation period.
  # Returns a hash of { resident_id => rounded_balance }.
  # Uses largest-remainder method (Hamilton's method) to round to cents,
  # guaranteeing the total sums to exactly zero.
  #
  # This method batch-loads all data upfront (5 queries total) to avoid the N+1
  # that would result from calling Meal#unit_cost per-record. The arithmetic is
  # identical to the per-record path (Meal#unit_cost, MealResident#cost, etc.)
  # but computed from in-memory data.
  #
  # Memory: loads all reconciled meals + associations into RAM. For a co-housing
  # community (~500 meals max), this is ~18K AR objects (~36 MB). Bounded by the
  # physical size of the community.
  def settlement_balances # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity -- financial settlement calculation, intentionally kept as single method for auditability
    # Step 1: Eager-load all reconciled meals with their financial associations.
    # Uses preload (not includes) to guarantee separate IN(?) queries — includes
    # can silently switch to LEFT JOIN if a .where is later chained on an
    # included table, which would produce a cartesian product across 3 associations.
    reconciled_meals = meals.with_attendees.preload(:bills, :meal_residents, :guests).to_a

    # Step 2: Precompute per-meal financials from in-memory data.
    # Uses block-form .sum(&:field) which invokes Enumerable#sum on the loaded
    # array. The column-form .sum(:field) always fires SQL even when loaded.
    # Stores total_cost and effective_cost alongside unit_cost so the credit
    # calculation in Step 3 can apply proportional capping for subsidized meals.
    meal_financials = {}
    reconciled_meals.each do |meal|
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

    # Step 3: Accumulate credits, debits, and guest debits from in-memory data.
    # All three use the already-loaded associations — zero additional queries.
    # Credits use the proportional capped amount: when a meal is subsidized
    # (cook spent more than the cap), each cook's credit is their proportional
    # share of the effective (capped) cost, not the raw bill amount.
    credits_by_resident = Hash.new(BigDecimal('0'))
    debits_by_resident = Hash.new(BigDecimal('0'))
    guest_debits_by_resident = Hash.new(BigDecimal('0'))

    reconciled_meals.each do |meal|
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
        credits_by_resident[b.resident_id] += credit
      end

      meal.meal_residents.each { |mr| debits_by_resident[mr.resident_id] += mf[:unit_cost] * mr.multiplier }
      meal.guests.each { |g| guest_debits_by_resident[g.resident_id] += mf[:unit_cost] * g.multiplier }
    end

    # Step 4: Assemble per-resident raw balances (1 query for residents, zero inside loop).
    raw_balances = {}
    community.residents.find_each do |resident|
      credits = credits_by_resident[resident.id]
      debits = debits_by_resident[resident.id]
      guest_debits = guest_debits_by_resident[resident.id]
      raw_balances[resident.id] = credits - debits - guest_debits
    end

    # Step 5: Round to cents using largest-remainder method (Hamilton's method).
    # This guarantees rounded balances sum to exactly zero — the standard
    # accounting approach for apportioning monetary amounts. Each value is
    # within 1 cent of its exact full-precision amount.
    balances = allocate_to_cents(raw_balances)

    # Verify the books balance exactly. allocate_to_cents guarantees this;
    # a non-zero sum indicates a bug in the allocation algorithm.
    total = balances.values.sum(BigDecimal('0'))
    unless total.zero?
      raise "settlement_balances: books do not balance for reconciliation #{id}. " \
            "Discrepancy: #{total}. This indicates a bug in allocate_to_cents."
    end

    balances
  end

  # Persist settlement balances to reconciliation_balances table.
  # Idempotent: clears existing balances first, then writes fresh values.
  # Only stores non-zero balances to keep the table lean.
  def persist_balances!
    balances = settlement_balances

    transaction do
      reconciliation_balances.delete_all
      balances.each do |resident_id, amount|
        next if amount.zero?

        reconciliation_balances.create!(resident_id: resident_id, amount: amount)
      end
    end
  end

  # Settlement balances grouped by unit. Returns { [unit_id, unit_name] => BigDecimal }
  # for every community unit, including units whose residents all have $0.00 balances.
  def unit_balances
    grouped = reconciliation_balances
              .joins(resident: :unit)
              .group('units.id', 'units.name')
              .sum(:amount)

    community.units.order(:name).each_with_object({}) do |unit, result|
      key = [unit.id, unit.name]
      result[key] = grouped[key] || BigDecimal('0')
    end
  end

  def balance_for(resident)
    reconciliation_balances.find_by(resident_id: resident.id)&.amount || BigDecimal('0')
  end

  private

  def finalize
    assign_meals
    persist_balances!
  end

  def set_date
    self.date ||= Time.zone.today
  end

  # Distributes full-precision balances (which sum to zero) into cent-rounded
  # balances that also sum to exactly zero, using the largest-remainder method
  # (Hamilton's method). Each rounded value is within 1 cent of its exact amount.
  #
  # Algorithm:
  # 1. Truncate each balance toward zero (floor positives, ceil negatives).
  # 2. Compute the residual = sum of truncated values (close to zero, off by a few cents).
  # 3. Award residual pennies to entries whose truncation discarded the most,
  #    tie-breaking by lowest resident_id for deterministic, auditable results.
  def allocate_to_cents(raw_balances)
    one_cent = BigDecimal('0.01')

    truncated = {}
    remainders = {}

    raw_balances.each do |id, raw|
      truncated[id] = raw >= 0 ? raw.floor(2) : raw.ceil(2)
      remainders[id] = raw - truncated[id]
    end

    residual = truncated.values.sum(BigDecimal('0'))
    pennies = (residual / one_cent).round.to_i

    if pennies.positive?
      # Sum too positive — subtract pennies from entries with most-negative remainders
      # (those entries benefited most from truncation toward zero).
      candidates = remainders.select { |_, r| r.negative? }.sort_by { |id, r| [r, id] }
      pennies.times { |i| truncated[candidates[i][0]] -= one_cent }
    elsif pennies.negative?
      # Sum too negative — add pennies to entries with most-positive remainders.
      candidates = remainders.select { |_, r| r.positive? }.sort_by { |id, r| [-r, id] }
      pennies.abs.times { |i| truncated[candidates[i][0]] += one_cent }
    end

    truncated
  end

  def start_date_not_after_end_date
    return unless start_date.present? && end_date.present?

    errors.add(:start_date, 'must be on or before end date') if start_date > end_date
  end
end
