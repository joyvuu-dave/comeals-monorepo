# typed: true
# frozen_string_literal: true

# How the direction of a balance is shown to humans.
#
# == The sign convention
#
# Every stored balance and every settlement line is signed the same way. The
# convention is set in one place, MealLedger (see its "Signs" section), and
# everything downstream inherits it:
#
#   positive  =>  the community owes this person money  ("is owed")
#   negative  =>  this person owes the community money   ("owes")
#
# == The display rule: no screen shows the sign
#
# A minus sign has no fixed meaning for money. A bank statement, a credit
# card statement, and an accountant's ledger disagree about what negative
# means, so a reader cannot learn it once and trust it — even the person who
# wrote this system kept getting it backwards. Words cannot be misread.
#
# So every human-facing balance must render through balance_tag, and every
# settlement line through charge_amount_tag. They print an unsigned dollar
# amount with a word that says the direction, and never print the sign.
# Do not call number_to_currency directly on a signed amount anywhere a
# person will read it.
module BalanceDisplayHelper
  extend T::Helpers

  requires_ancestor { ActionView::Base }

  # A signed balance, as words: "is owed $12.50", "owes $12.50", or "$0.00".
  #
  # The direction is decided from the amount rounded to cents, not the raw
  # sign, so a balance of -$0.001 reads as "$0.00" rather than "owes $0.00".
  def balance_tag(amount)
    cents = amount.round(2)

    if cents.positive?
      tag.span("is owed #{number_to_currency(cents)}", class: 'balance-is-owed')
    elsif cents.negative?
      tag.span("owes #{number_to_currency(cents.abs)}", class: 'balance-owes')
    else
      tag.span(number_to_currency(0), class: 'balance-zero')
    end
  end

  # Like balance_tag, but with every digit the amount has: "owes $0.00000001".
  # For the ledger check page, where a difference smaller than a cent is
  # the thing being shown, so rounding to cents would hide it. The
  # direction comes from the sign itself, for the same reason.
  def exact_balance_tag(amount)
    if amount.positive?
      tag.span("is owed #{exact_dollars(amount)}", class: 'balance-is-owed')
    elsif amount.negative?
      tag.span("owes #{exact_dollars(amount.abs)}", class: 'balance-owes')
    else
      tag.span(number_to_currency(0), class: 'balance-zero')
    end
  end

  # The sum of a settlement's meal lines, which must be zero, as words. A
  # credit is positive and a charge is negative (MealLedger, "Signs"), so a
  # sum above zero means the credits are bigger.
  def lines_total_words(total)
    if total.positive?
      "Credits are #{exact_dollars(total)} more than charges."
    elsif total.negative?
      "Charges are #{exact_dollars(total.abs)} more than credits."
    else
      'Credits and charges are equal.'
    end
  end

  # A settlement line (MealCharge), as words: a credit is money the community
  # owes the cook ("credited $16.00"), a debit is money the eater owes
  # ("charged $8.00"). The kind decides the word; the amount's sign always
  # agrees with it, because MealLedger writes both.
  def charge_amount_tag(charge)
    if charge.credit?
      tag.span("credited #{number_to_currency(charge.amount)}", class: 'balance-is-owed')
    else
      tag.span("charged #{number_to_currency(charge.amount.abs)}", class: 'balance-owes')
    end
  end

  # The footer under a settlement table. A single "Total: $0.00" is true but
  # says nothing; splitting it shows the amounts moving in each direction and
  # makes the zero-sum check visible. The difference is always zero —
  # settlement verifies it before writing — so a non-zero one is shown in the
  # error color: it means the stored balances no longer match what was
  # settled, which ledger:verify would also catch. Like a balance, it says
  # its direction in words ("$8.00 more owed by units"), never with a sign.
  def settlement_totals_tag(amounts, noun)
    owed_to = amounts.select(&:positive?).sum(BigDecimal('0'))
    owed_by = amounts.select(&:negative?).sum(BigDecimal('0')).abs
    difference = owed_to - owed_by

    lines = [
      tag.div("Owed to #{noun}: #{number_to_currency(owed_to)}"),
      tag.div("Owed by #{noun}: #{number_to_currency(owed_by)}"),
      if difference.zero?
        tag.div('Difference: $0.00 ✓')
      else
        more_owed = difference.positive? ? 'to' : 'by'
        tag.div("Difference: #{number_to_currency(difference.abs)} more owed #{more_owed} #{noun}",
                class: 'balance-owes')
      end
    ]
    tag.div(safe_join(lines), class: 'settlement-total')
  end

  private

  # A dollar amount with at least two decimals and every digit it has:
  # 40 is "$40.00", 0.00000001 is "$0.00000001". BigDecimal all the way.
  def exact_dollars(amount)
    number_to_currency(amount, precision: [2, amount.scale].max)
  end
end
