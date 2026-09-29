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

    it 'says nothing about extras for a meal that is over' do
      meal = create(:meal, community: community, date: Date.new(2026, 4, 9))
      meal.update!(closed: true, max: 4)

      expect(chip(meal)[:title]).to eq("Dinner\n0 attended")
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
        start: Time.zone.local(2026, 4, 15, 14, 0), end: Time.zone.local(2026, 4, 15, 16, 0),
        url: "common-house-reservations/edit/#{reservation.id}", description: "Common House\nCal - Unit B7",
        color: '#bc357e'
      )
    end

    # The SPA's form sends an empty title as "", which is stored as it is.
    it 'leaves the title line out when there is no title, or an empty one' do
      reservation = create(:common_house_reservation, community: community, resident: resident, title: nil,
                                                      start_date: Time.zone.local(2026, 4, 15, 14, 0),
                                                      end_date: Time.zone.local(2026, 4, 15, 16, 0))

      expect(chip(reservation)[:title]).to eq(" 2:00pm -  4:00pm\nCommon House\nCal - Unit B7")

      reservation.update!(title: '')
      expect(chip(reservation)[:title]).to eq(" 2:00pm -  4:00pm\nCommon House\nCal - Unit B7")
    end

    # Before #104 both ends were sent one minute late, so a booking that
    # ends at midnight ended at 00:01 on the chip, and the month view drew
    # it on the next day too.
    it 'starts and ends the chip at the booking\'s own times, like a timed event' do
      reservation = create(:common_house_reservation, community: community, resident: resident, title: 'Late',
                                                      start_date: Time.zone.local(2026, 4, 15, 22, 0),
                                                      end_date: Time.zone.local(2026, 4, 16, 0, 0))

      expect(chip(reservation)).to include(start: Time.zone.local(2026, 4, 15, 22, 0),
                                           end: Time.zone.local(2026, 4, 16, 0, 0))
    end
  end

  # The chip goes on the birthday in the year of the days on screen, and
  # names the age the person turns that day (#101). The clock is April
  # 10, 2026, so "today's year" and "today's age" would give other
  # answers in every example below.
  describe ResidentBirthdaySerializer do
    include_context 'with a fixed calendar day'

    # The six weeks the calendar shows for April 2026.
    let(:april_2026) { Date.new(2026, 3, 29)..Date.new(2026, 5, 9) }

    def chip(resident, days = april_2026)
      described_class.new(resident, params: { days: days }).to_h
    end

    def born(name, birthday)
      create(:resident, community: community, unit: unit, name: name, birthday: birthday)
    end

    it 'draws a child\'s birthday with the age they turn that day' do
      child = create(:resident, community: community, unit: unit, name: 'Dee Park', multiplier: 1,
                                birthday: Date.new(2016, 4, 20))

      expect(chip(child)).to eq(
        id: child.cache_key_with_version, type: 'Birthday', title: "Dee's 10th B-day!",
        description: "Dee's 10th Birthday!", start: Date.new(2026, 4, 20), end: Date.new(2026, 4, 20),
        color: '#7335bc'
      )
    end

    it 'says the same age on the same chip before, on and after the birthday' do
      child = born('Dee Park', Date.new(2016, 4, 20))

      titles = [Time.zone.local(2026, 4, 19, 12, 0), Time.zone.local(2026, 4, 20, 12, 0),
                Time.zone.local(2026, 4, 21, 12, 0)].map do |now|
        travel_to(now)
        chip(child)[:title]
      end

      expect(titles).to eq(["Dee's 10th B-day!"] * 3)
    end

    it 'shows the age up to 21, and leaves it out from 22 on' do
      twenty_one = born('Hal Kim', Date.new(2005, 4, 11))
      turning = born('Fay Tan', Date.new(2004, 4, 11))
      adult = born('Eve Ruiz', Date.new(2004, 4, 9))

      expect(chip(twenty_one)).to include(title: "Hal's 21st B-day!", description: "Hal's 21st Birthday!")
      expect(chip(turning)).to include(title: "Fay's B-day!", description: "Fay's Birthday!")
      expect(chip(adult)).to include(title: "Eve's B-day!", description: "Eve's Birthday!")
    end

    it 'dates each chip in the year its month has on a grid that crosses New Year' do
      november = born('Ann Lee', Date.new(1990, 11, 30))
      december = born('Bo Chu', Date.new(1990, 12, 31))
      january = born('Cy Dunn', Date.new(1990, 1, 3))
      december_2026 = Date.new(2026, 11, 29)..Date.new(2027, 1, 9)

      expect([november, december, january].map { |resident| chip(resident, december_2026)[:start] })
        .to eq([Date.new(2026, 11, 30), Date.new(2026, 12, 31), Date.new(2027, 1, 3)])

      january_2027 = Date.new(2026, 12, 27)..Date.new(2027, 2, 6)
      expect([december, january].map { |resident| chip(resident, january_2027)[:start] })
        .to eq([Date.new(2026, 12, 31), Date.new(2027, 1, 3)])
    end

    it 'counts the age from the year on screen, a year back or ahead of today' do
      child = born('Dee Park', Date.new(2016, 4, 20))

      expect(chip(child, Date.new(2025, 3, 30)..Date.new(2025, 5, 10))).to include(
        title: "Dee's 9th B-day!", start: Date.new(2025, 4, 20), end: Date.new(2025, 4, 20)
      )
      expect(chip(child, Date.new(2027, 3, 28)..Date.new(2027, 5, 8))).to include(
        title: "Dee's 11th B-day!", start: Date.new(2027, 4, 20), end: Date.new(2027, 4, 20)
      )
    end

    # Feb 29 on the February grids of 2026 (no Feb 29), 2027 (none) and
    # 2028 (a leap year). In the years without one the chip goes on the
    # 28th and still names the age turned that year: Resident#age_on
    # adds the year on March 1, so it would name one less.
    it 'puts a February 29 birthday on the 28th in a year without one, with the age turned that year' do
      leapling = born('Gus Vo', Date.new(2000, 2, 29))
      child = born('Kim Oh', Date.new(2016, 2, 29))

      expect(chip(leapling, Date.new(2026, 2, 1)..Date.new(2026, 3, 14)))
        .to include(start: Date.new(2026, 2, 28), end: Date.new(2026, 2, 28))
      expect(chip(child, Date.new(2027, 1, 31)..Date.new(2027, 3, 13)))
        .to include(title: "Kim's 11th B-day!", start: Date.new(2027, 2, 28), end: Date.new(2027, 2, 28))
      expect(chip(child, Date.new(2028, 1, 30)..Date.new(2028, 3, 11)))
        .to include(title: "Kim's 12th B-day!", start: Date.new(2028, 2, 29), end: Date.new(2028, 2, 29))
    end

    # Without the days it cannot know the year, and it must not guess
    # this year: that guess was the bug.
    it 'refuses to draw a chip without the days on screen' do
      child = born('Dee Park', Date.new(2016, 4, 20))

      expect { described_class.new(child).to_h }.to raise_error(KeyError, /days/)
    end
  end

  describe RotationSerializer do
    include_context 'with a fixed calendar day'

    def chip(rotation)
      described_class.new(rotation).to_h
    end

    # The meals are made out of date order, and neither the first nor
    # the last one made is the earliest or the latest. That takes four:
    # with three, the first or the last one made is one of the two ends.
    # The loaded meals are read in the order they were made. With no
    # ORDER BY they come back in the order PostgreSQL stored them, which
    # an earlier example's rows can change, and mutant saw taking the
    # last meal for the latest pass that way.
    it 'spans the first meal to the end of the last meal\'s day, loaded or not' do
      rotation = create(:rotation, community: community, no_email: true)
      create(:meal, community: community, rotation: rotation, date: Date.new(2026, 4, 12))
      create(:meal, community: community, rotation: rotation, date: Date.new(2026, 4, 5))
      create(:meal, community: community, rotation: rotation, date: Date.new(2026, 4, 19))
      create(:meal, community: community, rotation: rotation, date: Date.new(2026, 4, 15))
      expected = {
        id: rotation.reload.cache_key_with_version, type: 'Rotation', start: Time.zone.local(2026, 4, 5, 0, 1),
        end: Time.zone.local(2026, 4, 19, 23, 59), color: rotation.color, title: 'Rotation 1',
        url: "rotations/show/#{rotation.id}"
      }

      expect(chip(Rotation.find(rotation.id))).to eq(expected)
      loaded = Rotation.eager_load(:meals).order('meals.id').find(rotation.id)
      expect(loaded.meals).to be_loaded
      expect(loaded.meals.map { |meal| meal.date.day }).to eq([12, 5, 19, 15])
      expect(chip(loaded)).to eq(expected)
    end

    # The two ways to the dates give the same chip, so only the reads
    # tell them apart. The calendar preloads every rotation's meals, and
    # a chip that asked for MIN and MAX anyway would read twice a
    # rotation. A chip on its own must not load every meal of its
    # rotation to find two dates.
    it 'reads the dates from loaded meals with no query, and otherwise without loading the meals' do
      rotation = create(:rotation, community: community, no_email: true)
      create(:meal, community: community, rotation: rotation, date: Date.new(2026, 4, 5))
      create(:meal, community: community, rotation: rotation, date: Date.new(2026, 4, 19))
      loaded = Rotation.preload(:meals).find(rotation.id)
      unloaded = Rotation.find(rotation.id)
      statements = []
      callback = ->(*, payload) { statements << payload[:sql] }

      ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') { chip(loaded) }
      expect(statements).to be_empty

      expect(chip(unloaded))
        .to include(start: Time.zone.local(2026, 4, 5, 0, 1), end: Time.zone.local(2026, 4, 19, 23, 59))
      expect(unloaded.meals).not_to be_loaded
    end

    it 'has no start or end without meals' do
      rotation = create(:rotation, community: community, no_email: true)

      expect(chip(rotation)).to include(start: nil, end: nil)
      expect(chip(Rotation.preload(:meals).find(rotation.id))).to include(start: nil, end: nil)
    end
  end
end
