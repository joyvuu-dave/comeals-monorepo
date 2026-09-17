# typed: strict
# frozen_string_literal: true

# Shares a whole number of units out in proportion to weights, so that the
# shares add up to exactly the number of units that was shared.
#
# This is how the ledger splits a meal's cost without dividing: an effective
# cost across the eaters by multiplier, and on a subsidized meal across the
# cooks by what each spent (MODELS.md, "The ledger grain"). Dividing would
# leave a remainder that has to go somewhere, and the column would round
# it away silently, so a meal's stored lines would not sum to zero (#85).
#
# Largest remainder (Hamilton's method), the same rule
# Settlement.allocate_to_cents uses at the cent:
#
#   1. Each share first gets the whole units of its exact share
#      (total * weight / sum of weights, rounded down).
#   2. The units left over, fewer than there are shares, go one each to
#      the shares whose exact share lost the most in step 1.
#   3. Ties go to the earlier position. The caller puts the weights in
#      tie-break order (lowest resident id first, and so on).
#
# Every share is within one unit of its exact share. A share with weight
# zero, or whose exact share is a whole number, never gets a leftover unit:
# the leftover is the sum of the fractions dropped in step 1, and only a
# share that dropped a fraction can be among the largest.
class LargestRemainderSplit
  extend T::Sig

  # total: the units to share, not negative. weights: one per share, not
  # negative, not all zero, in tie-break order. Returns one Integer per
  # weight, in the same order, summing to total.
  sig { params(total: Integer, weights: T::Array[Integer]).returns(T::Array[Integer]) }
  def self.call(total, weights)
    whole = check!(total, weights)

    # (total * weight) divided by whole: the whole units, and what was
    # dropped, as a numerator over `whole`. Comparing the dropped
    # numerators compares the dropped fractions exactly, since the
    # denominator is the same for every share.
    shares = weights.map { |weight| (total * weight) / whole }
    dropped = T.let(Array.new(weights.size) do |index|
      (total * T.must(weights[index])) - (T.must(shares[index]) * whole)
    end, T::Array[Integer])
    leftover = total - shares.sum
    return shares if leftover.zero?

    # Most dropped first, then the earlier position. A comparison block
    # rather than sort_by, which would build a key array per share, and a
    # settlement splits a few thousand lines.
    ranked = shares.each_index.to_a.sort do |a, b|
      by_dropped = T.must(dropped[b]) <=> T.must(dropped[a])
      by_dropped.zero? ? a <=> b : by_dropped
    end
    ranked.first(leftover).each { |index| shares[index] = T.must(shares[index]) + 1 }

    shares
  end

  # The sum of the weights, after refusing an input the rule has no
  # answer for.
  sig { params(total: Integer, weights: T::Array[Integer]).returns(Integer) }
  def self.check!(total, weights)
    raise ArgumentError, "cannot split #{total}: it is negative" if total.negative?
    raise ArgumentError, 'cannot split among no shares' if weights.empty?
    raise ArgumentError, "a weight is negative: #{weights.inspect}" if weights.any?(&:negative?)

    whole = weights.sum
    raise ArgumentError, 'cannot split when every weight is zero' if whole.zero?

    whole
  end
  private_class_method :check!
end
