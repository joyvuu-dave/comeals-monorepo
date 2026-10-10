# frozen_string_literal: true

require 'rails_helper'

# Two common house bookings must not hold the same time. The model
# refuses an overlap with a sentence (period_is_free); this EXCLUDE makes
# PostgreSQL refuse it from every write that skips the model, and from two
# bookings saved at the same moment, which each check before the other is
# written (#149).
#
# The EXCLUDE compares each booking as the range [start, end): a booking
# that ends as another starts does not overlap it. A booking that ends
# when it starts is an empty range, which overlaps nothing. A midnight
# notice is one, and so are the old rows from before #141.
RSpec.describe 'common house bookings never overlap' do
  let!(:resident) { create(:resident) }

  # A time on 2026-04-12 in the app zone, Los Angeles.
  def at(hour, minute = 0)
    Time.zone.local(2026, 4, 12, hour, minute)
  end

  # A row written the way psql or insert_all writes it: no model.
  def insert(start, finish)
    CommonHouseReservation.insert!({ community_id: resident.community_id, resident_id: resident.id,
                                     start_date: start, end_date: finish })
  end

  # Each write runs in its own savepoint: a refused statement ends the
  # transaction it runs in, and the example's transaction must go on.
  def database_takes?(start, finish)
    CommonHouseReservation.transaction(requires_new: true) { insert(start, finish) }
    true
  rescue ActiveRecord::ExclusionViolation
    false
  end

  def model_takes?(start, finish)
    booking = build(:common_house_reservation, resident: resident, start_date: start, end_date: finish)
    booking.period_is_free
    booking.errors.empty?
  end

  it 'refuses a booking that overlaps another, from a write that skips the model' do
    booking = create(:common_house_reservation, resident: resident, start_date: at(9), end_date: at(10))
    create(:common_house_reservation, resident: resident, start_date: at(11), end_date: at(12))

    expect do
      booking.update_columns(end_date: at(11, 30))
    end.to raise_error(ActiveRecord::ExclusionViolation, /common_house_reservations_no_overlap/)
  end

  # Each case is a booking already in the table and a new one, as hours on
  # one day. The model and the database must give the same answer for
  # each, or a save the model allows fails in the database (a 500), or
  # the model refuses a save the database would take.
  it 'agrees with the model about every kind of pair' do
    cases = {
      'apart' => [[at(9), at(10)], [at(11), at(12)]],
      'the new one starts as the old one ends' => [[at(9), at(10)], [at(10), at(11)]],
      'the new one ends as the old one starts' => [[at(10), at(11)], [at(9), at(10)]],
      "over the old one's end" => [[at(9), at(11)], [at(10), at(12)]],
      "over the old one's start" => [[at(10), at(12)], [at(9), at(11)]],
      'inside the old one' => [[at(9), at(12)], [at(10), at(11)]],
      'around the old one' => [[at(10), at(11)], [at(9), at(12)]],
      'the same times' => [[at(9), at(10)], [at(9), at(10)]],
      'a new one that ends when it starts, inside the old one' => [[at(9), at(12)], [at(10), at(10)]],
      'an old one that ends when it starts, inside the new one' => [[at(10, 30), at(10, 30)], [at(9), at(12)]],
      'two that end when they start, at one moment' => [[at(10), at(10)], [at(10), at(10)]],
      'a midnight notice, and a booking from that midnight' => [[at(0), at(0)], [at(0), at(2)]]
    }

    seen = cases.transform_values do |(saved, new)|
      answer = nil
      CommonHouseReservation.transaction(requires_new: true) do
        insert(*saved)
        answer = { model: model_takes?(*new), database: database_takes?(*new) }
        raise ActiveRecord::Rollback
      end
      answer
    end

    taken = ["over the old one's end", "over the old one's start", 'inside the old one', 'around the old one',
             'the same times']
    expect(seen).to eq(cases.keys.index_with do |name|
      free = taken.exclude?(name)
      { model: free, database: free }
    end)
  end
end
