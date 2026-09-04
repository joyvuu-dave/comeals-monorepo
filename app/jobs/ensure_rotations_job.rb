# typed: true
# frozen_string_literal: true

# Make sure the meal calendar reaches at least six months ahead, creating
# rotations until it does. Nothing to do is the normal outcome.
class EnsureRotationsJob < RecurringJob
  HEALTHCHECK = 'community-create-rotations'
  HORIZON = 6.months

  def run
    community = Community.instance

    # A meal without a rotation would make the loop below spin forever. This
    # must fail loudly, not log and succeed: a job that "works" while doing
    # nothing would quietly stop extending the calendar until it ran out.
    if community.meals.exists?(rotation_id: nil)
      raise "#{community.name} has one or more meals that are not assigned to a rotation. " \
            'Fix them, then rerun.'
    end

    created = 0
    while community.meals.where(date: (community.today + HORIZON)..).blank?
      community.create_next_rotation
      created += 1
    end
    Rails.logger.info("ensure_rotations: #{created} rotation(s) created") if created.positive?
    { rotations_created: created }
  end
end
