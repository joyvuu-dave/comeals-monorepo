# frozen_string_literal: true

namespace :history do
  # Run once on production, after a backup, by the person who knows which
  # account the shared screen used. Without WRITE=yes it only counts:
  #
  #   RESIDENT_ID=... BEFORE=2021-10-26T00:00:00-07:00 bin/rails history:relabel_as_common_house
  #   RESIDENT_ID=... BEFORE=2021-10-26T00:00:00-07:00 WRITE=yes bin/rails history:relabel_as_common_house
  desc "Name the Common House in the history rows a resident's account wrote before BEFORE (WRITE=yes to change)."
  task relabel_as_common_house: :environment do
    resident_id = Integer(ENV.fetch('RESIDENT_ID'))
    before = CommonHouseHistory.parse_instant(ENV.fetch('BEFORE'))
    write = ENV['WRITE'] == 'yes'

    count = CommonHouseHistory.relabel(resident_id: resident_id, before: before, write: write)
    rows = count == 1 ? '1 history row' : "#{count} history rows"
    if write
      puts "Relabeled #{rows} as the Common House."
    else
      puts "#{rows} would be relabeled as the Common House. " \
           "Run again with WRITE=yes to change #{count == 1 ? 'it' : 'them'}."
    end
  end
end
