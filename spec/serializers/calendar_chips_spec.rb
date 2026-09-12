# frozen_string_literal: true

require 'rails_helper'

# The whole payload of each calendar chip, value by value. The contract
# spec pins the keys and the serializers spec a few words; this pins
# what the SPA draws: the exact title and description text, the start
# and end the calendar places the chip by, the link, the colour, and
# the cache key the SPA dedups by.
#
# Names have unique first names, so ResidentNameShortener shortens each
# to its first name. Dates sit around Friday April 10, 2026, which the
# clock is set to.
RSpec.shared_context 'with a fixed calendar day' do
  include ActiveSupport::Testing::TimeHelpers

  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community, name: 'B7') }

  before do
    travel_to(Time.zone.local(2026, 4, 10, 12, 0))
    community
  end
end

RSpec.describe 'the calendar chips', type: :serializer do
  describe MealSerializer do
    include_context 'with a fixed calendar day'

    let(:resident) { create(:resident, community: community, unit: unit, name: 'Ann Lee', multiplier: 2) }

    def chip(meal)
      described_class.new(meal).to_h
    end

    it 'draws a past meal with how many attended' do
      meal = create(:meal, community: community, date: Date.new(2026, 4, 9), description: 'Soup')
      create(:meal_resident, meal: meal, resident: resident, community: community)

      expect(chip(meal)).to eq(
        id: meal.cache_key_with_version, type: 'Meal', title: "Dinner\n1 attended",
        start: Time.zone.local(2026, 4, 9, 0, 1), end: Time.zone.local(2026, 4, 9, 0, 1),
        url: "/meals/#{meal.id}/edit", description: 'Soup', color: '#444'
      )
    end

    it 'draws today\'s meal with who is attending and the extras left' do
      meal = create(:meal, community: community, date: Date.new(2026, 4, 10))
      create(:meal_resident, meal: meal, resident: resident, community: community)
      meal.update!(closed: true, max: 4)

      expect(chip(meal)[:title]).to eq("Dinner\n1 attending\n 3 extras")
    end

    it 'says "extra" for one spot left' do
      meal = create(:meal, community: community, date: Date.new(2026, 4, 11))
      create(:meal_resident, meal: meal, resident: resident, community: community)
      meal.update!(closed: true, max: 2)

      expect(chip(meal)[:title]).to eq("Dinner\n1 signed up\n 1 extra")
    end

    it 'draws a future open meal with how many signed up and no extras line' do
      meal = create(:meal, community: community, date: Date.new(2026, 4, 11))

      expect(chip(meal)[:title]).to eq("Dinner\n0 signed up")
    end
  end

  describe BillSerializer do
    include_context 'with a fixed calendar day'

    let(:cook) { create(:resident, community: community, unit: unit, name: 'Ann Lee', multiplier: 2) }

    def chip(bill)
      described_class.new(bill).to_h
    end

    it 'draws a past receipt with the amount' do
      meal = create(:meal, community: community, date: Date.new(2026, 4, 9))
      bill = create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('50'))

      expect(chip(bill)).to eq(
        id: bill.cache_key_with_version, type: 'Bill', title: "Cook\nAnn - Unit B7\n$50.00",
        start: Time.zone.local(2026, 4, 9, 0, 1), end: Time.zone.local(2026, 4, 9, 0, 1),
        url: "/meals/#{meal.id}/edit", description: 'Cook:  Ann - Unit B7 - $50.00'
      )
    end

    it 'draws a future cook slot, and a past one with nothing spent, without an amount' do
      future = create(:meal, community: community, date: Date.new(2026, 4, 11))
      upcoming = create(:bill, meal: future, resident: cook, community: community, amount: BigDecimal('50'))
      past = create(:meal, community: community, date: Date.new(2026, 4, 9))
      free = create(:bill, meal: past, resident: cook, community: community, amount: BigDecimal('0'))

      [upcoming, free].each do |bill|
        expect(chip(bill)).to include(title: "Cook\nAnn - Unit B7", description: 'Cook:  Ann - Unit B7')
      end
    end
  end

  describe EventSerializer do
    include_context 'with a fixed calendar day'

    def chip(event)
      described_class.new(event).to_h
    end

    it 'draws a timed event with its hours' do
      event = create(:event, community: community, title: 'Movie Night', description: 'Bring popcorn',
                             start_date: Time.zone.local(2026, 4, 15, 19, 0),
                             end_date: Time.zone.local(2026, 4, 15, 21, 30), allday: false)

      expect(chip(event)).to eq(
        id: event.cache_key_with_version, type: 'Event', title: " 7:00pm -  9:30pm\nEvent\nMovie Night",
        description: "Event\nBring popcorn", start: Time.zone.local(2026, 4, 15, 19, 0),
        end: Time.zone.local(2026, 4, 15, 21, 30), url: "events/edit/#{event.id}", allDay: false, color: '#7ebc35'
      )
    end

    it 'draws an all-day event a minute into its day, with no hours' do
      event = create(:event, community: community, title: 'Work Day', description: '',
                             start_date: Time.zone.local(2026, 4, 15, 0, 0), end_date: nil, allday: true)

      expect(chip(event)).to include(
        title: "ALL DAY\nEvent\nWork Day", description: "Event\n", start: Time.zone.local(2026, 4, 15, 0, 1),
        end: Time.zone.local(2026, 4, 15, 0, 1), allDay: true
      )
    end
  end

  describe GuestRoomReservationSerializer do
    include_context 'with a fixed calendar day'

    it 'draws the booking by the resident and unit' do
      resident = create(:resident, community: community, unit: unit, name: 'Bea Ortiz')
      reservation = create(:guest_room_reservation, community: community, resident: resident,
                                                    date: Date.new(2026, 4, 15))

      expect(described_class.new(reservation).to_h).to eq(
        id: reservation.cache_key_with_version, type: 'GuestRoomReservation', title: "Guest Room\nBea - Unit B7",
        start: Time.zone.local(2026, 4, 15, 0, 1), end: Time.zone.local(2026, 4, 15, 0, 1),
        url: "guest-room-reservations/edit/#{reservation.id}", description: "Guest Room\nBea - Unit B7",
        color: '#bc7335'
      )
    end
  end

  describe CommonHouseReservationSerializer do
    include_context 'with a fixed calendar day'

    let(:resident) { create(:resident, community: community, unit: unit, name: 'Cal Ng') }

    def chip(reservation)
      described_class.new(reservation).to_h
    end

    it 'draws the hours, the title and the resident' do
      reservation = create(:common_house_reservation, community: community, resident: resident, title: 'Book club',
                                                      start_date: Time.zone.local(2026, 4, 15, 14, 0),
                                                      end_date: Time.zone.local(2026, 4, 15, 16, 0))

      expect(chip(reservation)).to eq(
        id: reservation.cache_key_with_version, type: 'CommonHouseReservation',
        title: " 2:00pm -  4:00pm\nCommon House\nBook club\nCal - Unit B7",
        start: Time.zone.local(2026, 4, 15, 14, 1), end: Time.zone.local(2026, 4, 15, 16, 1),
        url: "common-house-reservations/edit/#{reservation.id}", description: "Common House\nCal - Unit B7",
        color: '#bc357e'
      )
    end

    it 'leaves the title line out when there is no title' do
      reservation = create(:common_house_reservation, community: community, resident: resident, title: nil,
                                                      start_date: Time.zone.local(2026, 4, 15, 14, 0),
                                                      end_date: Time.zone.local(2026, 4, 15, 16, 0))

      expect(chip(reservation)[:title]).to eq(" 2:00pm -  4:00pm\nCommon House\nCal - Unit B7")
    end
  end

  describe ResidentBirthdaySerializer do
    include_context 'with a fixed calendar day'

    def chip(resident)
      described_class.new(resident).to_h
    end

    it 'draws a child\'s birthday with the age, on this year\'s date' do
      child = create(:resident, community: community, unit: unit, name: 'Dee Park', multiplier: 1,
                                birthday: Date.new(2016, 4, 20))

      expect(chip(child)).to eq(
        id: child.cache_key_with_version, type: 'Birthday', title: "Dee's 9th B-day!",
        description: "Dee's 9th Birthday!", start: Date.new(2026, 4, 20), end: Date.new(2026, 4, 20),
        color: '#7335bc'
      )
    end

    it 'leaves the age out from 22 on' do
      adult = create(:resident, community: community, unit: unit, name: 'Eve Ruiz', birthday: Date.new(2004, 4, 9))
      turning = create(:resident, community: community, unit: unit, name: 'Fay Tan', birthday: Date.new(2004, 4, 11))

      expect(chip(adult)).to include(title: "Eve's B-day!", description: "Eve's Birthday!")
      expect(chip(turning)).to include(title: "Fay's 21st B-day!", description: "Fay's 21st Birthday!")
    end

    it 'puts a February 29 birthday on the 28th in a year without one' do
      leapling = create(:resident, community: community, unit: unit, name: 'Gus Vo', birthday: Date.new(2000, 2, 29))

      expect(chip(leapling)).to include(start: Date.new(2026, 2, 28), end: Date.new(2026, 2, 28))
    end
  end

  describe RotationSerializer do
    include_context 'with a fixed calendar day'

    def chip(rotation)
      described_class.new(rotation).to_h
    end

    it 'spans the first meal to the end of the last meal\'s day, loaded or not' do
      rotation = create(:rotation, community: community, no_email: true)
      create(:meal, community: community, rotation: rotation, date: Date.new(2026, 4, 19))
      create(:meal, community: community, rotation: rotation, date: Date.new(2026, 4, 5))
      expected = {
        id: rotation.reload.cache_key_with_version, type: 'Rotation', start: Time.zone.local(2026, 4, 5, 0, 1),
        end: Time.zone.local(2026, 4, 19, 23, 59), color: rotation.color, title: 'Rotation 1',
        url: "rotations/show/#{rotation.id}"
      }

      expect(chip(Rotation.find(rotation.id))).to eq(expected)
      loaded = Rotation.preload(:meals).find(rotation.id)
      expect(loaded.meals).to be_loaded
      expect(chip(loaded)).to eq(expected)
    end

    it 'has no start or end without meals' do
      rotation = create(:rotation, community: community, no_email: true)

      expect(chip(rotation)).to include(start: nil, end: nil)
      expect(chip(Rotation.preload(:meals).find(rotation.id))).to include(start: nil, end: nil)
    end
  end
end
