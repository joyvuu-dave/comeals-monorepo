# typed: true
# frozen_string_literal: true

# Make sure the meal calendar reaches at least six months ahead, creating
# rotations until it does. Nothing to do is the normal outcome.
#
# From mid-9999 on, six months ahead is past the last day a dinner may
# have (CalendarWindow), so the calendar can never reach it. The job
# then makes dinners up to that day and stops when no meal day is left
# (Community#create_next_rotation answers nil).
class EnsureRotationsJob < RecurringJob
  HEALTHCHECK = 'community-create-rotations'
  HORIZON = 6.months

  def run
    community = Community.instance
    created = 0
    while community.meals.where(date: (community.today + HORIZON)..).blank?
      break unless community.create_next_rotation

      created += 1
    end
    Rails.logger.info("ensure_rotations: #{created} rotation(s) created") if created.positive?
    { rotations_created: created }
  end
end
