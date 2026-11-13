# typed: true
# frozen_string_literal: true

# The meal page's two writes to the state of a dinner: closing or
# reopening it, and cancelling or restoring it (ADR 0011 rule 11). Both
# set one true-or-false value under the meal lock. Included in
# Api::V1::MealsController, whose before_actions find the meal and
# refuse a settled one; what it provides (meal, render_refused,
# render_write_under_lock) is declared in
# sorbet/rbi/shims/concerns.rbi.
module MealStatusActions
  extend ActiveSupport::Concern
  extend T::Sig
  # On a settled meal, a close or a cancel that sends the value the meal
  # already has is answered as saved (#280). Included here, so the
  # controller gets it with this concern; its own checks use it too.
  include SettledSameValue

  # A filter of its own name, not reject_if_reconciled: Rails replaces a
  # before_action given the same method again, so naming that one here
  # would drop it from every other action in the controller.
  included do
    T.bind(self, T.class_of(ApiController))

    before_action :reject_status_change_if_reconciled, only: %i[update_closed update_cancelled]
  end

  # PATCH /api/v1/meals/:meal_id/closed { closed }
  # closed is required, and must be a value TrueOrFalse takes. Before
  # #138 "no" closed the meal, and before #139 a missing closed was a
  # 500.
  sig { void }
  def update_closed
    flags = TrueOrFalse.from_params(params, %i[closed], required: true)
    return render_refused(flags) if flags.is_a?(String)

    render_same_value_write({ json: { message: 'Meal closed value updated.' } }) do
      meal.update!(closed: flags.fetch(:closed))
    end
  end

  # PATCH /api/v1/meals/:meal_id/cancelled { cancelled }
  # Cancels the dinner, or restores it (ADR 0011 rule 11). Anyone who
  # can sign people up can do it, like closing a meal. A dinner a cook
  # spent money on is refused with a sentence (Meal#cancel!). Sending
  # the state it is in already changes nothing, so a second tap or a
  # retry after a lost answer is not an error, on a settled dinner too
  # (same_value_answer, #280).
  sig { void }
  def update_cancelled
    flags = TrueOrFalse.from_params(params, %i[cancelled], required: true)
    return render_refused(flags) if flags.is_a?(String)

    cancel = flags.fetch(:cancelled)
    render_same_value_write({ json: { message: cancel ? 'Dinner cancelled.' : 'Dinner restored.' } }) do
      cancel ? meal.cancel! : meal.restore!
    end
  end

  private

  sig { void }
  def reject_status_change_if_reconciled
    reject_if_reconciled
  end
end
