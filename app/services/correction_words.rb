# typed: strict
# frozen_string_literal: true

# Words for a correction to a settled dinner (ADR 0011 rule 6), from the
# record MealCorrecting keeps: what changed, before and after
# (MealCorrecting::Edits). One sentence for each edit. The admin pages and
# the API preview both read these, so the server says it one way.
class CorrectionWords
  extend T::Sig

  Residents = T.type_alias { T::Hash[Integer, Resident] }

  # One edit from MealCorrection#edits. `residents` maps id to Resident,
  # loaded once for the page; a resident it lacks is named by id.
  sig { params(edit: T::Hash[String, T.untyped], residents: Residents).returns(String) }
  def self.edit(edit, residents)
    name = residents[edit['resident_id']]&.name || "Resident ##{edit['resident_id']}"
    from = edit['from']
    to = edit['to']
    case edit['what']
    when 'cost' then cost(name, from, to)
    when 'eater' then eater(name, from, to)
    when 'guest' then guest(name, from, to)
    else "#{edit['what']}: #{from.inspect} to #{to.inspect}"
    end
  end

  # Every resident the corrections' edits name, by id, in one query.
  sig { params(corrections: T::Array[MealCorrection]).returns(Residents) }
  def self.residents_named_in(corrections)
    ids = corrections.flat_map { |correction| T.let(correction.edits, T::Array[T.untyped]).pluck('resident_id') }
    Resident.where(id: ids).index_by { |resident| T.must(resident.id) }
  end

  sig { params(name: String, from: T.untyped, to: T.untyped).returns(String) }
  def self.cost(name, from, to)
    return "Added #{name} as a cook (#{cost_words(to)})." if from.nil?
    return "Removed #{name} as a cook (#{cost_words(from)})." if to.nil?

    "Changed #{name}'s cost from #{cost_words(from)} to #{cost_words(to)}."
  end

  sig { params(name: String, from: T.untyped, to: T.untyped).returns(String) }
  def self.eater(name, from, to)
    return "Signed up #{name} (#{Multiplier.label(to)})." if from.nil?
    return "Removed #{name}'s sign-up (#{Multiplier.label(from)})." if to.nil?

    "Changed #{name}'s price from #{Multiplier.label(from)} to #{Multiplier.label(to)}."
  end

  sig { params(name: String, from: T.untyped, to: T.untyped).returns(String) }
  def self.guest(name, from, to)
    return "Added a guest of #{name} (#{Multiplier.label(to)})." if from.nil?

    "Removed a guest of #{name} (#{Multiplier.label(from)})."
  end

  # A cost as the cook's row says it: an amount, No cost, or blank (not
  # entered yet).
  sig { params(cost: T::Hash[String, T.untyped]).returns(String) }
  def self.cost_words(cost)
    return 'No cost' if cost['no_cost']

    amount = BigDecimal(cost['amount'])
    amount.zero? ? 'blank' : ActiveSupport::NumberHelper.number_to_currency(amount)
  end
  private_class_method :cost, :eater, :guest, :cost_words
end
