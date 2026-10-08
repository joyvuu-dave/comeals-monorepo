# typed: strict
# frozen_string_literal: true

# A bills save as a client sent it, checked, and then written to the
# meal's bill rows (#135, docs/adr/0009-bills-saves-send-edits.md).
#
# The wire shape (PATCH /api/v1/meals/:id/bills):
#
#   { edits: [
#     { op: "add",    resident_id: 7, to:   { amount: "12.50", no_cost: false } },
#     { op: "change", resident_id: 9, from: { amount: "5.0",   no_cost: false },
#                                     to:   { amount: "7.00",  no_cost: false } },
#     { op: "remove", resident_id: 4, from: { amount: "0.0",   no_cost: true } }
#   ] }
#
# Each edit names one cook. `from` is the bill the page saw for that cook,
# and `to` is the bill the person wants. A cook the edits do not name is
# never touched. So a page that has not yet seen another page's save
# cannot undo it: a cook the other page added is not named here, and a
# bill the other page changed no longer matches this edit's `from`.
#
# write_to compares each edit with the stored bill for its cook:
#
#   - the bill already is `to`, or a remove finds no bill: the edit is
#     done and nothing is written. So the same save sent twice is safe.
#   - the bill is `from`, or an add finds no bill: the edit is written.
#   - anything else: the meal changed after the page read it. Nothing at
#     all is written, and the answer says which cooks changed.
#
# "Is" means the same amount as a number ("5", "5.0" and "5.00" are the
# same, and "" is 0) and the same no_cost.
#
# A body with a `bills` key is the old format, from a page loaded before
# this change: the full list of cooks, where a cook left out was removed.
# It is refused as out of date and never written.
#
# Checking comes first and writes nothing, so a problem in any edit means
# no edit is written. The checks, in order, and the sentence each answers
# with (only the first problem is reported):
#
#   - edits is not a list of objects   "edits must be a list of changes."
#   - then each edit, in order:
#     - op is not add, change or remove
#                                      "Each edit's op must be add, change
#                                      or remove."
#     - the wrong sides for the op     "An add has 'to' and no 'from'.",
#                                      "A change has 'from' and 'to'.",
#                                      "A remove has 'from' and no 'to'."
#     - then `from`, then `to`, each checked for:
#       - not an object with both amount and no_cost
#                                      "'from' and 'to' each need amount
#                                      and no_cost."
#       - an amount that is not text, or not whole cents from 0 to 9999.99
#                                      "Invalid amount: X. Amounts are text
#                                      with whole cents, 0 to 9999.99, like
#                                      \"25.50\"."
#       - a no_cost that TrueOrFalse does not take
#                                      "No cost must be true or false"
#   - the same cook twice              "Duplicate cook in edits: resident #N."
#   - a cook who is not a resident, or a resident_id that is not a whole
#     number                           "Resident not found."
#
# A side sent as null is a side left out. A resident_id is a number, or
# a string of digits (a form-encoded body sends every value as text).
# no_cost follows the rule of every true/false value the API reads
# (TrueOrFalse, #138): true, false, 1 or 0, or the same as text.
#
# Amounts are text, never a JSON number: Rails reads a JSON number as a
# Float, so 25.499999999999999 would arrive as 25.5 and pass the grammar
# (money rule 1). The text is matched by grammar and never rounded: the
# SPA blocks the same shape (app/frontend/src/helpers/money.ts), and
# Bill's validation and the bills_amount_whole_cents CHECK constraint
# stand behind this.
class BillsPayload
  extend T::Sig

  WHOLE_CENTS_AMOUNT = T.let(/\A\d{1,4}(\.\d{1,2})?\z/, Regexp)
  RESIDENT_ID = T.let(/\A\d+\z/, Regexp)

  OUTDATED = T.let('Nothing was saved, because this page is out of date. ' \
                   'Please reload the page and enter the costs again.', String)

  class Op < T::Enum
    enums do
      Add = new('add')
      Change = new('change')
      Remove = new('remove')
    end
  end

  # The sides each kind of edit has, as [from, to], and the sentence for
  # an edit that has other sides.
  SIDES = T.let({
    Op::Add => [[false, true], "An add has 'to' and no 'from'."],
    Op::Change => [[true, true], "A change has 'from' and 'to'."],
    Op::Remove => [[true, false], "A remove has 'from' and no 'to'."]
  }.freeze, T::Hash[Op, [T::Array[T::Boolean], String]])

  # One side of an edit: a cook's bill as the page saw it (`from`), or as
  # the person wants it (`to`).
  class Values < T::Struct
    const :amount, BigDecimal
    const :no_cost, T::Boolean
  end

  # One cook's edit. A side that is nil means "no bill": an add has no
  # `from`, and a remove has no `to`. resident_id is nil when the id sent
  # was not a whole number; such an edit never passes the checks.
  class Edit < T::Struct
    extend T::Sig

    const :op, Op
    const :resident_id, T.nilable(Integer)
    const :from, T.nilable(Values)
    const :to, T.nilable(Values)

    # The stored bill already is what this edit asks for.
    sig { params(bill: T.nilable(Bill)).returns(T::Boolean) }
    def done?(bill) = matches?(to, bill)

    # The stored bill is the one the page saw, so the edit may be written.
    sig { params(bill: T.nilable(Bill)).returns(T::Boolean) }
    def built_on?(bill) = matches?(from, bill)

    # What changed since the page read the meal, for a bill that is
    # neither of the above.
    sig { params(bill: T.nilable(Bill), name: String).returns(String) }
    def change_seen(bill, name)
      if bill.nil? then "#{name} is no longer a cook"
      elsif op == Op::Add then "#{name} is already a cook"
      else "#{name}'s cost changed"
      end
    end

    private

    sig { params(side: T.nilable(Values), bill: T.nilable(Bill)).returns(T::Boolean) }
    def matches?(side, bill)
      return bill.nil? if side.nil?

      !bill.nil? && side.amount == bill.amount && side.no_cost == bill.no_cost
    end
  end

  # The sentence for the first thing wrong with the body, or nil when the
  # edits can be written.
  sig { returns(T.nilable(String)) }
  attr_reader :error

  sig { params(params: ActionController::Parameters).returns(BillsPayload) }
  def self.parse(params)
    new(params)
  end

  sig { params(params: ActionController::Parameters).void }
  def initialize(params)
    @outdated = T.let(params.key?(:bills), T::Boolean)
    @edits = T.let([], T::Array[Edit])
    @residents = T.let({}, T::Hash[Integer, Resident])
    @error = T.let(@outdated ? OUTDATED : check(params[:edits]), T.nilable(String))
  end

  # The body is in the old format, which listed every cook.
  sig { returns(T::Boolean) }
  def outdated?
    @outdated
  end

  sig { returns(T::Boolean) }
  def valid?
    error.nil?
  end

  # The SHA-256, in lowercase hex, of what the edits ask for: each edit as
  # [op, resident id, from, to], each side as [amount, no_cost], in the
  # order sent. The server keeps it next to the save's Idempotency-Key
  # (BillsSaveKey), to tell the same save sent again from another save
  # that reuses the key. Amounts are written as numbers, so "7" and "7.00"
  # are the same save, and the parts of the body that say nothing about
  # the bills (the Pusher socket id, a token) are left out: a resend after
  # a dropped connection comes with a new socket id. JSON.generate, not
  # to_json, so the text does not change with Rails' JSON settings while
  # a key is kept. Only meaningful when the payload is valid.
  sig { returns(String) }
  def fingerprint
    Digest::SHA256.hexdigest(JSON.generate(@edits.map { |edit| [edit.op.serialize, edit.resident_id, *sides(edit)] }))
  end

  # Writes the edits to the meal's bills, in the order sent, or writes
  # nothing and returns the sentence that says what changed since the
  # page read the meal. `stored` is the meal's bills by cook, read under
  # the meal lock, which the caller holds and rescues
  # (Api::V1::MealsController#with_meal_lock).
  #
  # Every write goes through the model (create!, update!, destroy!), so
  # the meal lock, the reconciled guard, the validations, the audit and
  # the live update all run, and a refusal raises and rolls back the
  # writes before it. A new bill gets its cook as the record the check
  # already loaded: its validation reads the cook, because Rails checks
  # that a belongs_to record exists when the foreign key is new, and with
  # the record in hand that read runs no query. A change reads no cook,
  # because its resident_id does not change.
  sig { params(meal: Meal, stored: T::Hash[Integer, Bill]).returns(T.nilable(String)) }
  def write_to(meal, stored)
    changes = @edits.filter_map do |edit|
      bill = stored[T.must(edit.resident_id)]
      edit.change_seen(bill, resident_of(edit).name.to_s) unless edit.done?(bill) || edit.built_on?(bill)
    end
    return stale(changes) if changes.any?

    @edits.each do |edit|
      bill = stored[T.must(edit.resident_id)]
      write(meal, edit, bill) unless edit.done?(bill)
    end
    nil
  end

  private

  sig { params(meal: Meal, edit: Edit, bill: T.nilable(Bill)).void }
  def write(meal, edit, bill)
    to = edit.to
    if to.nil?
      T.must(bill).destroy!
    elsif bill.nil?
      meal.bills.create!(resident: resident_of(edit), amount: to.amount, no_cost: to.no_cost)
    else
      bill.update!(amount: to.amount, no_cost: to.no_cost)
    end
  end

  # An edit's from and to as the fingerprint writes them: nil for a side
  # the edit does not have.
  sig { params(edit: Edit).returns(T::Array[T.nilable([String, T::Boolean])]) }
  def sides(edit)
    [edit.from, edit.to].map { |side| side && [side.amount.to_s('F'), side.no_cost] }
  end

  sig { params(changes: T::Array[String]).returns(String) }
  def stale(changes)
    "Nothing was saved, because this meal changed after you loaded it: #{changes.to_sentence}. " \
      'Check the cooks and costs, then enter your change again.'
  end

  # Every edit's cook was found, or the payload is not valid and nothing
  # is written.
  sig { params(edit: Edit).returns(Resident) }
  def resident_of(edit)
    @residents.fetch(T.must(edit.resident_id))
  end

  # Returns the first problem's sentence, or nil. Fills @edits and
  # @residents on the way; both are only meaningful when this returns nil.
  sig { params(raw: T.untyped).returns(T.nilable(String)) }
  def check(raw)
    return 'edits must be a list of changes.' unless raw.is_a?(Array) && raw.all? { |item| item.respond_to?(:key?) }

    raw.each do |item|
      parsed = edit(item)
      return parsed if parsed.is_a?(String)

      @edits << parsed
    end
    duplicate_cook || unknown_cook
  end

  # One edit as sent, or the sentence for what is wrong with it.
  sig { params(item: T.untyped).returns(T.any(Edit, String)) }
  def edit(item)
    op = Op.try_deserialize(item['op'])
    return "Each edit's op must be add, change or remove." if op.nil?

    sides, wrong = SIDES.fetch(op)
    return wrong unless sides == [!item['from'].nil?, !item['to'].nil?]

    from = side(item['from'])
    return from if from.is_a?(String)

    to = side(item['to'])
    return to if to.is_a?(String)

    Edit.new(op: op, resident_id: resident_id(item['resident_id']), from: from, to: to)
  end

  # One side as sent (nil when the edit has no such side), or the
  # sentence for what is wrong with it.
  sig { params(raw: T.untyped).returns(T.any(Values, String, NilClass)) }
  def side(raw)
    return nil if raw.nil?
    unless raw.respond_to?(:key?) && raw.key?('amount') && raw.key?('no_cost')
      return "'from' and 'to' each need amount and no_cost."
    end

    amount = amount(raw['amount'])
    return amount if amount.is_a?(String)

    no_cost = TrueOrFalse.read(raw['no_cost'])
    return TrueOrFalse.refusal(:no_cost) if no_cost.nil?

    Values.new(amount: amount, no_cost: no_cost)
  end

  # The amount, or the sentence for what is wrong with it. Only text is
  # taken; anything else is shown as the JSON it was.
  sig { params(raw: T.untyped).returns(T.any(BigDecimal, String)) }
  def amount(raw)
    if raw.is_a?(String) && (raw.empty? || WHOLE_CENTS_AMOUNT.match?(raw))
      return raw.empty? ? BigDecimal('0') : BigDecimal(raw)
    end

    shown = raw.is_a?(String) ? raw : raw.to_json
    "Invalid amount: #{shown}. Amounts are text with whole cents, 0 to 9999.99, like \"25.50\"."
  end

  sig { params(raw: T.untyped).returns(T.nilable(Integer)) }
  def resident_id(raw)
    return raw if raw.is_a?(Integer)

    Integer(raw, 10) if raw.is_a?(String) && RESIDENT_ID.match?(raw)
  end

  sig { returns(T.nilable(String)) }
  def duplicate_cook
    duplicate = @edits.filter_map(&:resident_id).tally.find { |_, count| count > 1 }&.first
    "Duplicate cook in edits: resident ##{duplicate}." if duplicate
  end

  # Loads the cooks on the way, for write_to.
  sig { returns(T.nilable(String)) }
  def unknown_cook
    ids = @edits.map(&:resident_id)
    known = ids.compact
    return 'Resident not found.' if known.size < ids.size

    @residents = Resident.where(id: known).index_by { |resident| T.must(resident.id) }
    'Resident not found.' if (known - @residents.keys).any?
  end
end
