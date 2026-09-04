# typed: true
# frozen_string_literal: true

# Move each resident with a birthday into the multiplier band their age
# puts them in (the community's free_below_age and full_price_age). Idempotent:
# a resident already in the right band is left alone.
#
# This is the one scheduled job that changes source data. Attendance
# snapshots the multiplier at sign-up, so a settled meal never changes, but
# a resident's rate is wrong between their birthday and this job's next run.
# Deriving the band at snapshot time instead would remove that gap; until
# then this job runs daily.
class SetMultipliersJob < RecurringJob
  HEALTHCHECK = 'residents-set-multiplier'

  def run
    moved = 0
    Resident.where.not(birthday: nil).includes(:community).find_each do |resident|
      new_multiplier = band_for(resident.age, resident.community)
      next if resident.multiplier == new_multiplier

      old_band = Multiplier.band_name(resident.multiplier)
      resident.update_columns(multiplier: new_multiplier) # -- the band is derived; validations have nothing to add
      moved += 1
      Rails.logger.info("residents:set_multiplier: #{resident.name} moved from #{old_band} to " \
                        "#{Multiplier.band_name(new_multiplier)}.")
    end
    { residents_moved: moved }
  end

  private

  def band_for(age, community)
    if age < community.free_below_age
      Multiplier::FREE
    elsif age < community.full_price_age
      Multiplier::HALF
    else
      Multiplier::FULL
    end
  end
end
