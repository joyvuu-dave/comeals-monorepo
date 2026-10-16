# typed: strict
# frozen_string_literal: true

# Whether a settled dinner's rows still add up to what it was settled at,
# plus every correction made to it since (ADR 0011 rule 6).
#
# A settlement stores each dinner's lines (meal_charges). A correction
# changes the dinner's rows and stores each person's change
# (meal_correction_lines). So for every person, at the ledger grain:
#
#   stored line + every correction line == what the rows add up to now
#
# When that holds, the dinner's rows changed only by corrections. When it
# does not, something changed them another way: psql with the repair
# bypass, or a bug. The nightly check reports it (LedgerVerification),
# and MealCorrecting refuses to correct such a dinner, because a
# correction works from the rows as they are and would fold the
# difference in under its own reason.
#
# A dinner nobody ate has no stored lines (a settlement writes none for
# it), and its rows add up to $0 credits for its cooks. A $0 amount is
# left out on both sides, so it agrees.
class SettledDinnerDifference
  extend T::Sig

  # resident_id => [settled plus corrections, rows now]
  People = T.type_alias { T::Hash[Integer, [BigDecimal, BigDecimal]] }

  ZERO = T.let(BigDecimal('0'), BigDecimal)

  # Each meal that disagrees, with the people it disagrees about. A meal
  # that agrees is not in the answer. The meals must come with their
  # bills, attendance and guests loaded, as MealLedger needs; three
  # queries for any number of meals.
  sig { params(meals: T::Array[Meal]).returns(T::Hash[Integer, People]) }
  def self.for(meals)
    ids = meals.map { |meal| T.must(meal.id) }
    settled = sums(MealCharge.where(meal_id: ids).group(:meal_id, :resident_id).sum(:amount))
    corrected = sums(MealCorrectionLine.joins(:meal_correction).where(meal_corrections: { meal_id: ids })
                                       .group('meal_corrections.meal_id', :resident_id).sum(:amount))
    now = T.let({}, T::Hash[[Integer, Integer], BigDecimal])
    MealLedger.new(meals).lines.each do |line|
      key = [line.meal_id, line.resident_id]
      now[key] = now.fetch(key, ZERO) + line.amount
    end

    differences(settled, corrected, now)
  end

  # A grouped sum, keyed [meal_id, resident_id]. Sorbet's relation sigs
  # know only the ungrouped, scalar form, so this sig says what it is.
  sig { params(grouped: T.untyped).returns(T::Hash[[Integer, Integer], BigDecimal]) }
  def self.sums(grouped)
    grouped
  end

  sig do
    params(settled: T::Hash[[Integer, Integer], BigDecimal],
           corrected: T::Hash[[Integer, Integer], BigDecimal], now: T::Hash[[Integer, Integer], BigDecimal])
      .returns(T::Hash[Integer, People])
  end
  def self.differences(settled, corrected, now)
    answer = T.let({}, T::Hash[Integer, People])
    (settled.keys | corrected.keys | now.keys).each do |key|
      expected = settled.fetch(key, ZERO) + corrected.fetch(key, ZERO)
      actual = now.fetch(key, ZERO)
      next if expected == actual

      meal_id, resident_id = key
      (answer[meal_id] ||= {})[resident_id] = [expected, actual]
    end
    answer
  end
  private_class_method :sums, :differences
end
