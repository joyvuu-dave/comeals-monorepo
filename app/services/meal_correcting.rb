# typed: strict
# frozen_string_literal: true

# Corrects a settled dinner (ADR 0011 rule 6).
#
# A settled dinner's rows are locked, and the settlement that settled it
# keeps what it settled. When a mistake is found later, a superuser
# corrects the dinner. Its rows change, with history, and each person's
# change in what they owe or are owed is saved as a line. The next
# settlement carries the correction: it adds those lines to the balances
# it rounds to cents.
#
#   MealCorrecting.preview(meal) { |edits| edits.cost(cook, amount: BigDecimal('17'), no_cost: false) }
#   # => a Result: what would change, and each person's change. Nothing is saved.
#
#   MealCorrecting.save!(meal, by: admin, reason: 'Typed $170 for $17',
#                              fingerprint: result.fingerprint) { |edits| ... }
#   # => the MealCorrection
#
# The edits a correction may make are the ones in Edits: a cook's cost,
# adding or removing a cook, adding or removing an eater, an eater's price,
# and adding or removing a guest (decision B, 2026-10-13). The block runs
# the same edits for the preview and for the save.
#
# The money: work the dinner out from its rows before the edits and after
# them (MealLedger), and take the difference for each person, at the
# ledger grain. A meal's lines add up to zero before and after, so the
# changes do too, and the database checks that again.
#
# Before the edits, the dinner's rows must add up to what it was settled
# at plus its earlier corrections (SettledDinnerDifference). If they do
# not, something else changed them, and this refuses: the correction
# would fold that difference in under its own reason.
#
# The dinner's row is locked FOR UPDATE first, so two corrections of one
# dinner run one after the other. The writes to its rows are let through
# by the database setting comeals.correcting, which names the dinner for
# this transaction only, and goes back to empty when the correction is
# saved. Everything happens in one savepoint, so a refusal leaves nothing.
class MealCorrecting
  extend T::Sig

  # The dinner is not settled. An open dinner is changed directly.
  class NotSettled < StandardError; end

  # The dinner was cancelled, so it charged nobody whatever its rows say,
  # and a correction has nothing to change (ADR 0011 rule 11).
  class Cancelled < StandardError; end

  # The dinner's rows already differ from what it was settled at plus its
  # corrections. The nightly check reports the same difference.
  class EarlierDifference < StandardError; end

  # The edits changed nothing.
  class NothingChanged < StandardError; end

  # The save was given the fingerprint of a preview, and the dinner or the
  # edits came out different: someone changed the dinner after the preview
  # was made.
  class Changed < StandardError; end

  # The database setting the trigger and ReconciledMealImmutability read
  # (20261010125952).
  CORRECTING_SETTING = 'comeals.correcting'

  # What a correction changes: the edits, in the words of the record
  # (MealCorrection#edits), and each person's change at the ledger grain.
  # Positive means the community owes the person more (MealLedger, "Signs").
  class Result < T::Struct
    extend T::Sig

    const :edits, T::Array[T::Hash[String, T.untyped]]
    const :changes, T::Hash[Integer, BigDecimal]

    # A short code made from the edits and the changes. The correction
    # form shows a preview and sends its code with Save, so a correction
    # never saves changes the admin did not see.
    sig { returns(String) }
    def fingerprint
      amounts = changes.sort.map { |id, amount| "#{id}:#{amount.to_s('F')}" }
      Digest::SHA256.hexdigest([edits.to_json, amounts.join(',')].join('|'))
    end
  end

  # What the correction would do, worked out by doing it and rolling it
  # back.
  sig { params(meal: Meal, blk: T.proc.params(edits: Edits).void).returns(Result) }
  def self.preview(meal, &blk) # rubocop:disable Naming/BlockForwarding, Style/ArgumentsForwarding -- the sig above has to name the block
    RetryOnConflict.call do
      result = T.let(nil, T.nilable(Result))
      Meal.transaction(requires_new: true) do
        result = apply(meal, &blk) # rubocop:disable Naming/BlockForwarding, Style/ArgumentsForwarding -- inside a block, Ruby allows no anonymous one
        raise ActiveRecord::Rollback
      end
      T.must(result)
    end
  end

  # Make the correction and record it. With a fingerprint (Result#fingerprint)
  # it raises Changed, saving nothing, when the correction comes out
  # different from that preview.
  sig do
    params(meal: Meal, by: AdminUser, reason: String, fingerprint: T.nilable(String),
           blk: T.proc.params(edits: Edits).void)
      .returns(MealCorrection)
  end
  def self.save!(meal, by:, reason:, fingerprint: nil, &blk) # rubocop:disable Style/ArgumentsForwarding -- the sig above has to name the block
    RetryOnConflict.call do
      Meal.transaction(requires_new: true) do
        # The reason is checked first, so a missing one is refused before
        # any row changes.
        correction = MealCorrection.new(meal: meal, admin_user: by, reason: reason)
        correction.validate!
        result = Audited.audit_class.as_user(by) { apply(meal, &blk) } # rubocop:disable Style/ArgumentsForwarding -- inside a block, Ruby allows no anonymous one
        raise Changed, 'The dinner changed after the preview was made, so nothing was saved.' if
          fingerprint && result.fingerprint != fingerprint

        record!(correction, result)
      end
    end
  end

  sig { params(meal: Meal, blk: T.proc.params(edits: Edits).void).returns(Result) }
  def self.apply(meal, &blk) # rubocop:disable Naming/BlockForwarding -- the sig above has to name the block
    meal.lock!
    if meal.reconciliation_id.nil?
      raise NotSettled, "Meal #{meal.id} is not settled. An open dinner is changed directly."
    end
    if meal.cancelled?
      raise Cancelled,
            "Meal #{meal.id} was cancelled, so it charged nobody and has nothing to correct."
    end

    refuse_an_earlier_difference!(meal)
    before = per_person(meal)
    write_setting(meal.id.to_s)
    edits = Edits.new(meal)
    yield edits
    raise NothingChanged, 'The correction changes nothing.' if edits.done.empty?

    Result.new(edits: edits.done, changes: changes(before, per_person(meal)))
  end

  sig { params(correction: MealCorrection, result: Result).returns(MealCorrection) }
  def self.record!(correction, result)
    correction.edits = result.edits
    correction.save!
    lines = result.changes.map do |resident_id, amount|
      { meal_correction_id: correction.id, resident_id: resident_id, amount: amount }
    end
    # One statement, so the sum-zero trigger sees every line at once.
    MealCorrectionLine.insert_all!(lines) if lines.any?
    write_setting('')
    correction
  end

  sig { params(meal: Meal).void }
  def self.refuse_an_earlier_difference!(meal)
    difference = SettledDinnerDifference.for([loaded(meal)])[T.must(meal.id)]
    return if difference.nil?

    raise EarlierDifference,
          "Meal #{meal.id}'s rows already differ from what it was settled at plus its corrections, for " \
          "#{difference.size} #{'person'.pluralize(difference.size)}. The nightly ledger check reports it. " \
          'See docs/runbooks/settled-data-repair.md.'
  end

  # What each person is credited or charged for the dinner, from its rows
  # as they are now.
  sig { params(meal: Meal).returns(T::Hash[Integer, BigDecimal]) }
  def self.per_person(meal)
    MealLedger.new([loaded(meal)]).lines.each_with_object({}) do |line, sums|
      sums[line.resident_id] = sums.fetch(line.resident_id, BigDecimal('0')) + line.amount
    end
  end

  # The meal read again, with what MealLedger needs.
  sig { params(meal: Meal).returns(Meal) }
  def self.loaded(meal)
    Meal.where(id: meal.id).preload(:bills, :meal_residents, :guests).sole
  end

  sig do
    params(before: T::Hash[Integer, BigDecimal], after: T::Hash[Integer, BigDecimal])
      .returns(T::Hash[Integer, BigDecimal])
  end
  def self.changes(before, after)
    zero = BigDecimal('0')
    (before.keys | after.keys).sort.index_with { |id| after.fetch(id, zero) - before.fetch(id, zero) }
                              .reject { |_, amount| amount.zero? }
  end

  # set_config(name, value, true) lasts until the end of the transaction,
  # and a savepoint that rolls back takes it back too.
  sig { params(value: String).void }
  def self.write_setting(value)
    Meal.connection.execute(Meal.sanitize_sql_array(['SELECT set_config(?, ?, true)', CORRECTING_SETTING, value]))
  end
  private_class_method :apply, :record!, :refuse_an_earlier_difference!, :per_person, :loaded, :changes,
                       :write_setting

  # The edits a correction may make to the dinner it corrects. Each one
  # saves through the model, so the model's rules apply (a cost in whole
  # cents, No cost with no amount, an eater's price from their age on the
  # dinner's date) and the audit history records it. The closed-dinner
  # rules do not apply (admin_correction): a settled dinner is closed, and
  # a correction is how its sign-ups are fixed.
  #
  # Each edit is recorded in `done`, as the correction's record keeps it:
  # what changed, whose row, and the value before and after. An edit that
  # changes nothing is not recorded.
  class Edits
    extend T::Sig

    # The record of one edit: "what" is cost, eater or guest; "resident_id"
    # is the cook, the eater, or the guest's host; "from" and "to" are the
    # values before and after, nil when the row was added or removed. A
    # cost is { "amount" => "17.0", "no_cost" => false }; a price is the
    # multiplier.
    Done = T.type_alias { T::Hash[String, T.untyped] }

    sig { returns(T::Array[Done]) }
    attr_reader :done

    sig { params(meal: Meal).void }
    def initialize(meal)
      @meal = meal
      @done = T.let([], T::Array[Done])
    end

    # A cook's cost: an amount, or No cost. A cook not on the dinner yet is
    # added with this cost.
    sig { params(cook: Resident, amount: BigDecimal, no_cost: T::Boolean).void }
    def cost(cook, amount:, no_cost:)
      bill = Bill.find_by(meal_id: @meal.id, resident_id: cook.id)
      if bill.nil?
        Bill.create!(meal: @meal, resident: cook, amount: amount, no_cost: no_cost)
        return record('cost', cook, nil, cost_of(amount, no_cost))
      end

      before = cost_of(T.must(bill.amount), T.must(bill.no_cost))
      bill.update!(amount: amount, no_cost: no_cost)
      record('cost', cook, before, cost_of(amount, no_cost)) if bill.saved_changes?
    end

    sig { params(cook: Resident).void }
    def remove_cook(cook)
      bill = Bill.find_by!(meal_id: @meal.id, resident_id: cook.id)
      bill.destroy!
      record('cost', cook, cost_of(T.must(bill.amount), T.must(bill.no_cost)), nil)
    end

    # At the resident's price for the dinner's date, as every sign-up is.
    sig { params(eater: Resident).void }
    def add_eater(eater)
      row = MealResident.new(meal: @meal, resident: eater)
      row.admin_correction = true
      row.save!
      record('eater', eater, nil, row.multiplier)
    end

    sig { params(eater: Resident).void }
    def remove_eater(eater)
      row = MealResident.find_by!(meal_id: @meal.id, resident_id: eater.id)
      row.admin_correction = true
      row.destroy!
      record('eater', eater, row.multiplier, nil)
    end

    # The eater's price set to the resident's price for the dinner's date
    # by today's rule: for the case where the price was wrong when they
    # signed up (a birthday fixed later, the wrong age band).
    sig { params(eater: Resident).void }
    def reprice_eater(eater)
      row = MealResident.find_by!(meal_id: @meal.id, resident_id: eater.id)
      before = row.multiplier
      row.admin_correction = true
      row.update!(multiplier: eater.multiplier_on(T.must(@meal.date)))
      record('eater', eater, before, row.multiplier) if row.saved_changes?
    end

    # A guest of `host`, at the adult or the child price (Multiplier::GUEST_PRICES).
    sig { params(host: Resident, multiplier: Integer).void }
    def add_guest(host, multiplier:)
      guest = Guest.new(meal: @meal, resident: host, multiplier: multiplier)
      guest.admin_correction = true
      guest.save!
      record('guest', host, nil, multiplier)
    end

    sig { params(guest: Guest).void }
    def remove_guest(guest)
      row = Guest.find_by!(id: guest.id, meal_id: @meal.id)
      row.admin_correction = true
      row.destroy!
      record('guest', T.must(row.resident), row.multiplier, nil)
    end

    private

    sig { params(amount: BigDecimal, no_cost: T::Boolean).returns(T::Hash[String, T.untyped]) }
    def cost_of(amount, no_cost)
      { 'amount' => amount.to_s('F'), 'no_cost' => no_cost }
    end

    sig { params(what: String, resident: Resident, from: T.untyped, to: T.untyped).void }
    def record(what, resident, from, to)
      @done << { 'what' => what, 'resident_id' => resident.id, 'from' => from, 'to' => to }
    end
  end
end
