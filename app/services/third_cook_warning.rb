# frozen_string_literal: true

# Cook-scheduling guard for the bills form. Warns when a payload adds or
# switches a third cook on a future meal while another meal in the rotation
# still has fewer than two cooks. The bills are saved either way — the
# warning only tells the user the rotation is understaffed. Compares the
# incoming cook ids against the stored bills, so run it before the bills
# are written.
class ThirdCookWarning
  def self.for(meal, cook_ids)
    new(meal, cook_ids).message
  end

  def initialize(meal, cook_ids)
    @meal = meal
    @cook_ids = cook_ids
  end

  # The warning text, or nil when the payload raises no concern.
  def message
    return nil unless @meal.date > Time.zone.today
    return nil unless @cook_ids.length > 2
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

  def existing
    @existing ||= @meal.bills.pluck(:resident_id).map(&:to_s).sort
  end

  def incoming
    @incoming ||= @cook_ids.map(&:to_s).sort
  end

  def adding?
    incoming.length > existing.length
  end

  def switching?
    incoming.length == existing.length && incoming != existing
  end
end
