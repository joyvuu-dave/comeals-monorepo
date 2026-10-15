# typed: true
# frozen_string_literal: true

# Words for the admin settlement preview and its two buttons, "Mark
# these blank costs as No cost" (ADR 0011 rule 4) and "Mark these
# dinners as cancelled" (rule 11), in app/admin/reconciliation.rb.
module SettlementPreviewHelper
  extend T::Sig
  extend T::Helpers

  requires_ancestor { ActionView::Base }

  # The button under the dinners that wait for a cost.
  sig { params(count: Integer).returns(String) }
  def blank_cost_button_label(count)
    count == 1 ? 'Mark this blank cost as No cost' : "Mark these #{count} blank costs as No cost"
  end

  # The button under the dinners nobody cooked.
  sig { params(count: Integer).returns(String) }
  def cancel_dinners_button_label(count)
    count == 1 ? 'Mark this dinner as cancelled' : "Mark these #{count} dinners as cancelled"
  end

  # The note beside a blank cost whose dinner has no money on any cost.
  # Marking it No cost leaves the dinner with nothing to share, so
  # everyone who ate it is charged nothing.
  sig { params(meal: Meal).returns(T.nilable(String)) }
  def free_dinner_note(meal)
    return if meal.bills.any? { |bill| T.must(bill.amount).positive? }

    'No cook on this dinner has entered an amount. After this, it is free for everyone who ate.'
  end

  # What the yes did, for the notice on the preview. Every cost on the
  # list is in it: the ones marked, each one left alone and why, and how
  # many were deleted after the list was shown.
  sig { params(result: NoCostMarking::Result).returns(String) }
  def no_cost_marking_words(result)
    sentences = ["Marked #{pluralize(result.marked.size, 'cost')} as No cost."]
    result.left_alone.each do |left|
      bill = left.bill
      sentences << "Left alone: #{bill.date.iso8601}, #{T.must(bill.resident).name}, because #{left.reason}."
    end
    if result.gone.positive?
      sentences << "#{pluralize(result.gone, 'cost')} on the list #{result.gone == 1 ? 'was' : 'were'} " \
                   'deleted after the list was shown.'
    end
    sentences.join(' ')
  end

  # What the yes did, for the notice on the preview. Every dinner on the
  # list is in it: the ones cancelled, each one left alone and why, and
  # how many were deleted after the list was shown.
  sig { params(result: DinnerCancelling::Result).returns(String) }
  def dinner_cancelling_words(result)
    sentences = ["Marked #{pluralize(result.cancelled.size, 'dinner')} as cancelled."]
    result.left_alone.each do |left|
      sentences << "Left alone: #{T.must(left.meal.date).iso8601}, because #{left.reason}."
    end
    if result.gone.positive?
      sentences << "#{pluralize(result.gone, 'dinner')} on the list #{result.gone == 1 ? 'was' : 'were'} " \
                   'deleted after the list was shown.'
    end
    sentences.join(' ')
  end
end
