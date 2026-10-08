# typed: true
# frozen_string_literal: true

# Cook-scheduling guard for the bills form. Warns when a save adds or
# switches a third cook on a future meal while another meal in the rotation
# still has fewer than two cooks. The bills are saved either way — the
# warning only tells the user the rotation is understaffed.
#
# Run it after the save has written, inside the meal lock
# (Api::V1::MealsController#save_bills). It is given the cooks as they
# were before the save, and reads the cooks after the save from the
# database, so it describes what the save did. A save names only the
# cooks it changes (#135), so the list it sent is not the meal's cooks.
class ThirdCookWarning
  extend T::Sig

  sig { params(meal: Meal, cooks_before: T::Array[Integer]).returns(T.nilable(String)) }
  def self.for(meal, cooks_before)
    new(meal, cooks_before).message
  end

  sig { params(meal: Meal, cooks_before: T::Array[Integer]).void }
  def initialize(meal, cooks_before)
    @meal = meal
    @before = T.let(cooks_before.sort, T::Array[Integer])
  end

  # The warning text, or nil when the save raises no concern.
  sig { returns(T.nilable(String)) }
  def message
    return nil unless T.must(@meal.date) > Community.instance.today
    return nil unless after.length > 2
    return nil unless adding? || switching?
    return nil unless @meal.another_meal_in_this_rotation_has_less_than_two_cooks?

    if adding?
      'Warning: third cooks should not be added until all meals ' \
        'in the rotation have at least two cooks.'
    else
      'Warning: third cook should not be switched when there are ' \
        'other meals in the rotation without at least two cooks.'
    end
  end

  private

  # A read of the table, not of the meal's loaded bills: a bill the save
  # destroyed is still in that list in memory. Sorted, because the
  # database returns rows in no set order (an updated row comes back
  # last), and switching? compares the two lists as they are.
  sig { returns(T::Array[Integer]) }
  def after
    @after ||= T.let(Bill.where(meal_id: @meal.id).pluck(:resident_id).sort, T.nilable(T::Array[Integer]))
  end

  sig { returns(T::Boolean) }
  def adding?
    after.length > @before.length
  end

  sig { returns(T::Boolean) }
  def switching?
    after.length == @before.length && after != @before
  end
end
