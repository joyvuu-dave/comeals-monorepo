# frozen_string_literal: true

namespace :community do
  desc 'Automatically create rotations so we always have 6 mo worth.'
  task create_rotations: :environment do
    Healthcheck.monitor('community-create-rotations') do
      Rails.logger.info 'Starting community:create_rotations'
      start_time = Time.current

      community = Community.instance
      Rails.logger.info "Examining #{community.name}:#{community.id}"

      # A meal without a rotation would make the catch-up loop below spin
      # forever. This must fail loudly (exit 1, fail ping), not log and
      # exit 0: a scheduled task that "succeeds" while doing nothing would
      # quietly stop extending the meal calendar until it runs out.
      if community.meals.exists?(rotation_id: nil)
        raise "#{community.name}:#{community.id} has one or more meals that are not " \
              'assigned to a rotation. Fix them, then rerun community:create_rotations.'
      end

      if community.meals.where(date: (Time.zone.today + 6.months)..).blank?
        Rails.logger.info 'We need to create some meals...'
        count = 0

        while community.meals.where(date: (Time.zone.today + 6.months)..).blank?
          Rails.logger.info 'Creating rotation...'
          community.create_next_rotation
          Rails.logger.info '...rotation created.'
          count += 1
        end

        Rails.logger.info("#{count} Rotations Created!")
      else
        Rails.logger.info "#{community.name}:#{community.id} was not in need of a new rotation."
      end

      total_time = Time.current - start_time
      Rails.logger.info("community:create_rotations complete in #{total_time}s.")
    end
  end
end
