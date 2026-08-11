# frozen_string_literal: true

namespace :residents do
  desc "Automatically set residents' multiplier based on their age."
  task set_multiplier: :environment do
    Healthcheck.monitor('residents-set-multiplier') do
      start_time = Time.current

      # A resident with no birthday is an adult who did not give one. Skip
      # them: their multiplier stays whatever the admin set.
      Resident.where.not(birthday: nil).find_each do |resident|
        age = resident.age

        resident.update_columns(multiplier: 0) and next if age < 5

        resident.update_columns(multiplier: 1) and next if age >= 5 && age < 12

        resident.update_columns(multiplier: 2) if age >= 12
      end

      total_time = Time.current - start_time
      Rails.logger.info("Residents' Multiplier Update Complete in #{total_time}s.")
    end
  end
end
