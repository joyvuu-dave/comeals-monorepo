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
#
# The write is update_columns, so Resident#note_live_update does not run
# and the job pushes for itself: once per run, only when someone moved,
# from inside the one transaction the moves commit in, so the moves and
# the push commit together or not at all. The band decides who is on the
# hosts list (Resident.adult), and a screen keeps its hosts list until a
# push, so without one a person who came of age was missing from the host
# dropdown on every open tab until it reloaded, for days on a shared
# screen (cache hunt, 2026-09-21). Pushing is the models' job (CLAUDE.md,
# rule 8); three writes skip the model on purpose and push for
# themselves: a settlement's claim, Rotation#set_place_value, and this one
# (ADR 0007).
class SetMultipliersJob < RecurringJob
  HEALTHCHECK = 'residents-set-multiplier'

  def run
    moved = 0
    # One transaction, so a run that fails after some moves leaves nobody
    # in a new band with no push: the moves roll back with it, and the
    # retry (RecurringJob) makes them again and pushes.
    Resident.transaction do
      Resident.where.not(birthday: nil).includes(:community).find_each do |resident|
        new_multiplier = band_for(resident.age, resident.community)
        next if resident.multiplier == new_multiplier

        old_band = Multiplier.band_name(resident.multiplier)
        resident.update_columns(multiplier: new_multiplier) # -- the band is derived; validations have nothing to add
        moved += 1
        Rails.logger.info("residents:set_multiplier: #{resident.name} moved from #{old_band} to " \
                          "#{Multiplier.band_name(new_multiplier)}.")
      end
      LiveUpdate.residents if moved.positive?
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
