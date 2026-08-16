# frozen_string_literal: true

namespace :residents do
  desc "Automatically set residents' multiplier based on their age."
  task set_multiplier: :environment do
    Healthcheck.monitor('residents-set-multiplier') do
      start_time = Time.current

      # Community.first, not Community.instance: on a fresh deployment with
      # no community there are no residents either (community_id is NOT
      # NULL), so the loop below runs zero times and raising would only
      # turn an empty run into a failed healthcheck.
      community = Community.first

      # A resident with no birthday is an adult who did not give one. Skip
      # them: their multiplier stays whatever the admin set.
      Resident.where.not(birthday: nil).find_each do |resident|
        age = resident.age
        new_multiplier = if age < community.free_below_age
                           Multiplier::FREE
                         elsif age < community.full_price_age
                           Multiplier::HALF
                         else
                           Multiplier::FULL
                         end
        next if resident.multiplier == new_multiplier

        old_band = Multiplier.band_name(resident.multiplier)
        resident.update_columns(multiplier: new_multiplier)
        Rails.logger.info("residents:set_multiplier: #{resident.name} moved from " \
                          "#{old_band} to #{Multiplier.band_name(new_multiplier)}.")
      end

      total_time = Time.current - start_time
      Rails.logger.info("Residents' Multiplier Update Complete in #{total_time}s.")
    end
  end
end
