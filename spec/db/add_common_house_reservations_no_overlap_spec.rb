# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('db/migrate/20261009171700_add_common_house_reservations_no_overlap.rb')

# The migration that adds the EXCLUDE refuses to run while two common
# house bookings overlap, and names each pair with its times in the
# community's zone, the way admin shows them. Without the guard the
# release would fail with a message about a constraint, and the person
# deploying would have to find the bookings by hand.
RSpec.describe AddCommonHouseReservationsNoOverlap do
  let(:connection) { ActiveRecord::Base.connection }
  let!(:resident) { create(:resident) }

  def at(hour)
    Time.zone.local(2026, 4, 12, hour)
  end

  def insert(start, finish)
    CommonHouseReservation.insert!({ community_id: resident.community_id, resident_id: resident.id,
                                     start_date: start, end_date: finish }, returning: :id).first['id']
  end

  # suppress_messages keeps the migration's "-- select_rows ..." lines
  # out of the RSpec output.
  def refuse_overlapping_bookings!
    migration = described_class.new
    migration.suppress_messages { migration.send(:refuse_overlapping_bookings) }
  end

  # The EXCLUDE forbids the overlapping rows below, so drop it for each
  # example (rolled back with the transaction).
  before do
    connection.remove_exclusion_constraint(:common_house_reservations, name: 'common_house_reservations_no_overlap')
  end

  # The booking that ends when it starts is inside another one: an empty
  # range overlaps nothing, as the EXCLUDE sees it. The model can save a
  # booking in the first hours PostgreSQL can store (StorableTime, #102),
  # which PostgreSQL cannot read in Los Angeles time: Los Angeles kept
  # local mean time then, 7:52:58 behind UTC. Only a booking in a pair is
  # read in the zone.
  it 'passes when bookings only touch, and when one that ends when it starts is inside another' do
    insert(at(9), at(10))
    insert(at(10), at(12))
    insert(at(11), at(11))
    insert(Time.utc(-4713, 11, 24, 0, 0, 58), Time.utc(-4713, 11, 24, 0, 52, 58))

    expect { refuse_overlapping_bookings! }.not_to raise_error
  end

  it 'refuses, naming each pair and its times, when bookings overlap' do
    first = insert(at(18), at(21))
    second = insert(at(19), at(20))
    third = insert(at(20), at(22))

    expect { refuse_overlapping_bookings! }.to raise_error(
      RuntimeError,
      "2 pair(s) of common house bookings overlap: #{first} (2026-04-12 18:00 to 2026-04-12 21:00) " \
      "and #{second} (2026-04-12 19:00 to 2026-04-12 20:00), " \
      "#{first} (2026-04-12 18:00 to 2026-04-12 21:00) and #{third} (2026-04-12 20:00 to 2026-04-12 22:00). " \
      'Times are in America/Los_Angeles. Move or delete one booking of each pair, then run this migration again.'
    )
  end
end
