# frozen_string_literal: true

require 'rails_helper'

RSpec.describe CalendarSerializer, type: :serializer do
  include ActiveSupport::Testing::TimeHelpers

  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:resident) { create(:resident, community: community, unit: unit, birthday: Date.new(1990, 4, 15)) }

  let(:start_date) { '2026-04-01' }
  let(:end_date) { '2026-04-30' }
  let(:options) do
    {
      month: 4, year: 2026,
      start_date: start_date, end_date: end_date,
      month_int_array: [4]
    }
  end

  def serialize
    described_class.new(community, params: options).to_h
  end

  describe 'top-level attributes' do
    it 'includes month and year' do
      result = serialize
      expect(result[:month]).to eq(4)
      # The SPA shows every time in the community's zone and takes the zone
      # from a login cookie; the month payload is how a changed zone reaches
      # a tab that is already open.
      expect(result[:timezone]).to eq('America/Los_Angeles')
      expect(result[:year]).to eq(2026)
    end
  end

  describe 'meals' do
    it 'includes meals within the date range' do
      create(:meal, community: community, date: Date.new(2026, 4, 10))
      create(:meal, community: community, date: Date.new(2026, 6, 10))

      result = serialize
      meal_dates = result[:meals].map { |m| m[:start].to_date }
      expect(meal_dates).to include(Date.new(2026, 4, 10))
      expect(meal_dates).not_to include(Date.new(2026, 6, 10))
    end
  end

  describe 'bills' do
    it 'includes bills for meals within the date range' do
      meal = create(:meal, community: community, date: Date.new(2026, 4, 15))
      cook = create(:resident, community: community, unit: unit)
      create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('50'))

      result = serialize
      expect(result[:bills].length).to eq(1)
    end
  end

  describe 'rotations' do
    it 'includes rotations that have meals in the date range' do
      rotation = create(:rotation, community: community)
      create(:meal, community: community, rotation: rotation, date: Date.new(2026, 4, 5))

      result = serialize
      expect(result[:rotations].length).to eq(1)
    end

    it 'excludes rotations with no meals in the range' do
      rotation = create(:rotation, community: community)
      create(:meal, community: community, rotation: rotation, date: Date.new(2026, 8, 1))

      result = serialize
      expect(result[:rotations].length).to eq(0)
    end
  end

  describe 'birthdays' do
    it 'includes active residents with birthdays in the month' do
      resident # force creation (April birthday)
      result = serialize
      expect(result[:birthdays].length).to eq(1)
      expect(result[:birthdays].first[:type]).to eq('Birthday')
    end

    it 'excludes inactive residents' do
      resident.update!(active: false, can_cook: false, email: nil)
      result = serialize
      expect(result[:birthdays].length).to eq(0)
    end

    # The December 2026 grid: November 29, 2026 to January 9, 2027. The
    # clock is in September, so "this year" would put the January chip
    # a year early, off the grid (#101).
    it 'dates each birthday in the year its month has in the window, across New Year' do
      travel_to Time.zone.local(2026, 9, 27, 12, 0) do
        options.merge!(month: 12, start_date: '2026-11-29', end_date: '2027-01-09', month_int_array: [11, 12, 1])
        [Date.new(1990, 11, 30), Date.new(1990, 12, 31), Date.new(1990, 1, 3)].each do |birthday|
          create(:resident, community: community, unit: unit, birthday: birthday)
        end

        expect(serialize[:birthdays].pluck(:start))
          .to eq([Date.new(2026, 11, 30), Date.new(2026, 12, 31), Date.new(2027, 1, 3)])
      end
    end

    # A person has no birthday chip before they were born. Born on the
    # last day of the window counts as born by then.
    it 'takes no birthday of someone born after the last day of the window' do
      travel_to Time.zone.local(2026, 9, 27, 12, 0) do
        baby = create(:resident, community: community, unit: unit, birthday: Date.new(2026, 4, 30))

        expect(serialize[:birthdays].pluck(:id, :start)).to eq([[baby.cache_key_with_version, Date.new(2026, 4, 30)]])

        options.merge!(year: 2025, start_date: '2025-04-01', end_date: '2025-04-30')
        expect(serialize[:birthdays]).to eq([])
      end
    end
  end

  describe 'events' do
    it 'includes events within the date range' do
      create(:event, community: community,
                     start_date: Time.zone.local(2026, 4, 10, 18, 0),
                     end_date: Time.zone.local(2026, 4, 10, 20, 0))

      result = serialize
      expect(result[:events].length).to eq(1)
    end

    it 'includes events that span across the date range boundaries' do
      create(:event, community: community,
                     start_date: Time.zone.local(2026, 3, 28, 0, 0),
                     end_date: Time.zone.local(2026, 4, 5, 0, 0))

      result = serialize
      expect(result[:events].length).to eq(1)
    end
  end

  describe 'common_house_reservations' do
    it 'includes reservations within the date range' do
      create(:common_house_reservation, community: community, resident: resident,
                                        start_date: Time.zone.local(2026, 4, 12, 14, 0),
                                        end_date: Time.zone.local(2026, 4, 12, 17, 0))

      result = serialize
      expect(result[:common_house_reservations].length).to eq(1)
    end
  end

  # Without ORDER BY, rows come back in the order they happen to be
  # stored in, and moving a booking to another day stores it again,
  # after the others. The month's ETag is a digest of the payload, so an
  # order that moves with no change to what is shown would send the whole
  # month again.
  describe 'the order of common house bookings' do
    it 'is by id, even after the first one is moved to a later day' do
      first = create(:common_house_reservation, community: community, resident: resident,
                                                start_date: Time.zone.local(2026, 4, 20, 14, 0),
                                                end_date: Time.zone.local(2026, 4, 20, 17, 0))
      second = create(:common_house_reservation, community: community, resident: resident,
                                                 start_date: Time.zone.local(2026, 4, 10, 14, 0),
                                                 end_date: Time.zone.local(2026, 4, 10, 17, 0))
      first.update!(start_date: Time.zone.local(2026, 4, 21, 14, 0), end_date: Time.zone.local(2026, 4, 21, 17, 0))

      expect(serialize[:common_house_reservations].pluck(:id))
        .to eq([first.cache_key_with_version, second.cache_key_with_version])
    end
  end

  describe 'guest_room_reservations' do
    it 'includes reservations within the date range' do
      create(:guest_room_reservation, community: community, resident: resident,
                                      date: Date.new(2026, 4, 20))

      result = serialize
      expect(result[:guest_room_reservations].length).to eq(1)
    end
  end

  # April 1 to April 30, both days whole. Every one-day-out record sits
  # here beside one on the edge, because a window that leaks a day, or
  # drops its last day, looked exactly like a good one to the examples
  # above.
  describe 'the window edges' do
    it 'takes meals, cook slots and guest room bookings on the first and last day, and not a day outside' do
      cook = create(:resident, community: community, unit: unit)
      [Date.new(2026, 3, 31), Date.new(2026, 4, 1), Date.new(2026, 4, 30), Date.new(2026, 5, 1)].each do |date|
        meal = create(:meal, community: community, date: date)
        create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('10'))
        create(:guest_room_reservation, community: community, resident: resident, date: date)
      end

      result = serialize

      inside = [Date.new(2026, 4, 1), Date.new(2026, 4, 30)]
      expect(result[:meals].map { |chip| chip[:start].to_date }).to match_array(inside)
      expect(result[:bills].map { |chip| chip[:start].to_date }).to match_array(inside)
      expect(result[:guest_room_reservations].map { |chip| chip[:start].to_date }).to match_array(inside)
    end

    it 'takes a common house booking from midnight on the first day to the last minute of the last' do
      [[3, 31, 23, 50], [4, 1, 0, 0], [4, 30, 23, 50], [5, 1, 0, 0]].each do |month, day, hour, minute|
        start = Time.zone.local(2026, month, day, hour, minute)
        create(:common_house_reservation, community: community, resident: resident,
                                          start_date: start, end_date: start + 9.minutes)
      end

      result = serialize

      starts = result[:common_house_reservations].pluck(:start)
      expect(starts).to contain_exactly(Time.zone.local(2026, 4, 1, 0, 0), Time.zone.local(2026, 4, 30, 23, 50))
    end

    # The same edges as the event example below. The admin form takes
    # any start and end, so a booking can last days. Each one here is
    # made alone, because two that overlap cannot both be saved.
    # prosopite: false, because the month is built once per booking on
    # purpose, and that repeats every query of the month.
    it 'takes a common house booking that ends inside, starts inside, or spans the window, like an event',
       prosopite: false do
      bookings = {
        'ends as the window opens' => [[3, 31, 22, 0], [4, 1, 0, 0]],
        'ends a minute before it' => [[3, 31, 22, 0], [3, 31, 23, 59]],
        'starts before it and ends inside' => [[3, 28, 18, 0], [4, 3, 10, 0]],
        'starts inside and ends after' => [[4, 30, 23, 0], [5, 2, 10, 0]],
        'starts at its last microsecond' => [[4, 30, 23, 59, 59.999999r], [5, 1, 2, 0]],
        'spans it' => [[3, 20, 12, 0], [5, 10, 12, 0]],
        'starts as it closes' => [[5, 1, 0, 0], [5, 1, 2, 0]]
      }

      taken = bookings.transform_values do |(from, to)|
        booking = create(:common_house_reservation, community: community, resident: resident,
                                                    start_date: Time.zone.local(2026, *from),
                                                    end_date: Time.zone.local(2026, *to))
        ids = serialize[:common_house_reservations].pluck(:id)
        booking.destroy!
        ids.map { |id| id == booking.cache_key_with_version ? :it : id }
      end

      expect(taken).to eq('ends as the window opens' => [:it], 'ends a minute before it' => [],
                          'starts before it and ends inside' => [:it], 'starts inside and ends after' => [:it],
                          'starts at its last microsecond' => [:it], 'spans it' => [:it],
                          'starts as it closes' => [])
    end

    it 'takes an event that starts inside, ends inside, or spans the window, and not one entirely outside' do
      starts_inside = create(:event, community: community, start_date: Time.zone.local(2026, 4, 30, 23, 0),
                                     end_date: Time.zone.local(2026, 5, 1, 2, 0))
      ends_inside = create(:event, community: community, start_date: Time.zone.local(2026, 3, 31, 22, 0),
                                   end_date: Time.zone.local(2026, 4, 1, 0, 0))
      spans = create(:event, community: community, start_date: Time.zone.local(2026, 3, 20, 12, 0),
                             end_date: Time.zone.local(2026, 5, 10, 12, 0))
      create(:event, community: community, start_date: Time.zone.local(2026, 3, 31, 20, 0),
                     end_date: Time.zone.local(2026, 3, 31, 23, 59))
      create(:event, community: community, start_date: Time.zone.local(2026, 5, 1, 0, 0),
                     end_date: Time.zone.local(2026, 5, 1, 2, 0))

      result = serialize

      expect(result[:events].pluck(:id))
        .to match_array([starts_inside, ends_inside, spans].map(&:cache_key_with_version))
    end

    it 'takes birthdays in the listed months only, lowest id first' do
      resident
      create(:resident, community: community, unit: unit, birthday: Date.new(1988, 5, 3))
      second_april = create(:resident, community: community, unit: unit, birthday: Date.new(1992, 4, 2))

      result = serialize

      expect(result[:birthdays].pluck(:id))
        .to eq([resident, second_april].map(&:cache_key_with_version))
    end
  end
end
