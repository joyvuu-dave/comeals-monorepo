# typed: strict
# frozen_string_literal: true

# The list of cooks a client sent for a meal's bills, checked, and then
# written to the meal's bill rows.
#
# The wire shape (PATCH /api/v1/meals/:id/bills):
#
#   { bills: [{ resident_id: 3, amount: "12.50", no_cost: false },
#             { resident_id: 4 }] }
#
# A row with an amount or a no_cost key is a bill the person touched, and
# both stored values are rewritten from it. A row with neither names a
# cook the person did not touch: it keeps that cook's bill alive (a cook
# left out of the list is removed) and never rewrites the stored amount.
#
# Checking comes first and writes nothing, so a bad row anywhere in the
# list means no row is written. The checks, in order, and the sentence
# each answers with:
#
#   - not a list of rows           "bills must be a list of cooks."
#   - the same cook twice          "Duplicate cook in bills: resident #N."
#   - an amount that is not whole  "Invalid amount: X. Amounts are whole
#     cents, 0 to 9999.99          cents, 0 to 9999.99."
#   - a cook who is not a resident "Resident not found."
#
# Amounts are whole cents, 0 to 9999.99, and are matched by grammar, never
# rounded: the SPA blocks the same shape (app/frontend/src/helpers/money.ts),
# and Bill's validation and the bills_amount_whole_cents CHECK constraint
# stand behind this. A blank amount is zero.
#
# This used to be the body of Api::V1::MealsController#update_bills, one
# method that checked, warned, wrote and rendered (RubyCritic rated the
# controller D for it). The controller now does the request's part —
# the meal lock, the third-cook warning, the rendering — and this does
# the payload's.
class BillsPayload
  extend T::Sig

  WHOLE_CENTS_AMOUNT = T.let(/\A\d{1,4}(\.\d{1,2})?\z/, Regexp)

  class Row < T::Struct
    const :resident_id, T.untyped
    const :touched, T::Boolean
    const :amount, T.nilable(BigDecimal)
    const :no_cost, T.untyped
  end

  sig { returns(T.nilable(String)) }
  attr_reader :error

  # The cooks' ids as sent — strings or integers, whichever the client
  # used. Empty when the payload is invalid.
  sig { returns(T::Array[T.untyped]) }
  attr_reader :cook_ids

  # Reads the list and checks it. `error` is the sentence for the first
  # thing wrong, or nil when the payload can be written.
  sig { params(raw: T.untyped).returns(BillsPayload) }
  def self.parse(raw)
    new(raw)
  end

  sig { params(raw: T.untyped).void }
  def initialize(raw)
    @rows = T.let([], T::Array[Row])
    @cook_ids = T.let([], T::Array[T.untyped])
    @error = T.let(check(raw), T.nilable(String))
  end

  sig { returns(T::Boolean) }
  def valid?
    error.nil?
  end

  # Writes the rows to the meal's bills: cooks not in the list are
  # removed, touched rows are rewritten, and an untouched row for a cook
  # with no bill yet is created with the column defaults. Bills are
  # removed one by one with destroy!, never through the association's
  # assignment, so a removal a model guard refuses raises instead of
  # being swallowed, and the audited hooks run. The caller holds the meal
  # lock (Api::V1::MealsController#with_meal_lock) and rescues.
  sig { params(meal: Meal).void }
  def write_to(meal)
    meal.bills.where.not(resident_id: cook_ids).find_each(&:destroy!)
    @rows.each do |row|
      record = meal.bills.find_or_initialize_by(resident_id: row.resident_id)
      if row.touched
        record.update!(amount: row.amount, no_cost: row.no_cost)
      elsif record.new_record?
        record.save!
      end
    end
  end

  private

  # Returns the first problem's sentence, or nil. Fills @rows and
  # @cook_ids on the way; both are only meaningful when this returns nil.
  sig { params(raw: T.untyped).returns(T.nilable(String)) }
  def check(raw)
    # A form-encoded empty list arrives as one empty string, and a body
    # without the key as nil; either used to reach pluck below and answer
    # 500 (found by the random action sequences, 2026-09-09).
    return 'bills must be a list of cooks.' unless raw.is_a?(Array) && raw.all? { |bill| bill.respond_to?(:key?) }

    @cook_ids = raw.pluck('resident_id')
    duplicate_cook || bad_row(raw) || unknown_cook
  end

  sig { returns(T.nilable(String)) }
  def duplicate_cook
    duplicate = @cook_ids.map(&:to_i).tally.find { |_, count| count > 1 }&.first
    "Duplicate cook in bills: resident ##{duplicate}." if duplicate
  end

  # Parses every row into @rows, stopping at the first one that is wrong.
  sig { params(raw: T::Array[T.untyped]).returns(T.nilable(String)) }
  def bad_row(raw)
    raw.each do |bill|
      parsed = row(bill)
      return parsed if parsed.is_a?(String)

      @rows << parsed
    end
    nil
  end

  sig { returns(T.nilable(String)) }
  def unknown_cook
    valid_ids = Resident.where(id: @cook_ids).pluck(:id)
    'Resident not found.' if (@cook_ids.map(&:to_i) - valid_ids).any?
  end

  # One row as sent, or the sentence for what is wrong with it.
  sig { params(bill: T.untyped).returns(T.any(Row, String)) }
  def row(bill)
    return Row.new(resident_id: bill['resident_id'], touched: false, amount: nil, no_cost: nil) unless touched?(bill)

    text = bill['amount'].to_s
    text = '0' if text.blank?
    unless WHOLE_CENTS_AMOUNT.match?(text)
      return "Invalid amount: #{bill['amount']}. Amounts are whole cents, 0 to 9999.99."
    end

    Row.new(resident_id: bill['resident_id'], touched: true, amount: BigDecimal(text), no_cost: bill['no_cost'])
  end

  sig { params(bill: T.untyped).returns(T::Boolean) }
  def touched?(bill)
    bill.key?('amount') || bill.key?('no_cost')
  end
end
