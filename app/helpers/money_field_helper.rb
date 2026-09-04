# typed: true
# frozen_string_literal: true

# The value a money text field shows on an admin form. Money columns are
# DECIMAL(12,8), so the raw attribute renders as "16.0" — a money field
# shows two decimals instead. One home for the rules, so every money field
# renders the same way:
#
# - nil renders blank: no cap set, or a blank submit that failed validation
#   (Rails casts "" to nil for a decimal column).
# - With blank_when_zero, zero renders blank too — a new bill's amount is
#   the column default 0, and the cook's real cost must be typed.
# - A sub-cent value renders exactly as stored ("16.005"), so after a
#   "must be whole cents" error the field still shows the typo the error
#   names, not a rounded value that looks valid.
# - number_to_rounded rounds with BigDecimal math. format('%.2f', ...)
#   would convert through Float, which money never touches (CLAUDE.md).
module MoneyFieldHelper
  def money_field_value(amount, blank_when_zero: false)
    return nil if amount.nil?
    return nil if blank_when_zero && amount.zero?
    return amount.to_s('F') unless amount == amount.round(2)

    ActiveSupport::NumberHelper.number_to_rounded(amount, precision: 2)
  end
end
