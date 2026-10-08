# frozen_string_literal: true

# == Schema Information
#
# Table name: common_house_reservations
#
#  id           :bigint           not null, primary key
#  end_date     :datetime         not null
#  start_date   :datetime         not null
#  title        :string
#  created_at   :datetime         not null
#  updated_at   :datetime         not null
#  community_id :bigint           not null
#  resident_id  :bigint           not null
#
# Indexes
#
#  index_common_house_reservations_on_resident_id  (resident_id)
#  index_common_house_reservations_on_start_date   (start_date)
#
# Foreign Keys
#
#  fk_rails_...  (community_id => communities.id)
#  fk_rails_...  (resident_id => residents.id)
#

require 'rails_helper'

RSpec.describe CommonHouseReservation do
  describe 'validations' do
    it 'is valid with valid attributes' do
      reservation = build(:common_house_reservation)
      expect(reservation).to be_valid
    end

    it 'validates presence of resident' do
      reservation = build(:common_house_reservation, resident: nil)
      expect(reservation).not_to be_valid
      expect(reservation.errors[:resident]).to include('must exist')
    end

    it 'validates presence of start_date' do
      reservation = build(:common_house_reservation, start_date: nil)
      expect(reservation).not_to be_valid
      expect(reservation.errors[:start_date]).to include("can't be blank")
    end

    it 'validates presence of end_date' do
      reservation = build(:common_house_reservation, end_date: nil)
      expect(reservation).not_to be_valid
      expect(reservation.errors[:end_date]).to include("can't be blank")
    end
  end

  # The admin forms and a task save through the model, not the API's
  # parser, so the model refuses a time the database cannot store
  # (StorableTime). Before, the overlap check sent the time to
  # PostgreSQL, which refused the query: a 500.
  describe 'a time the database cannot store' do
    let(:first) { StorableTime::TIMESTAMPS.begin }
    let(:last) { StorableTime::TIMESTAMPS.end - Rational(1, 1_000_000) }
    let(:refused) { ['is not a date the database can store'] }

    def errors_of(reservation)
      reservation.validate
      reservation.errors.to_hash
    end

    it 'refuses a start a second before the first instant, or an end a second after the last, under that time' do
      expect(errors_of(build(:common_house_reservation, start_date: first - 1.second, end_date: first + 1.hour)))
        .to eq(start_date: refused)
      expect(errors_of(build(:common_house_reservation, start_date: last - 1.hour, end_date: last + 1.second)))
        .to eq(end_date: refused)
    end

    it 'takes the first and the last instant, and still checks the overlap there' do
      taken = create(:common_house_reservation, start_date: last - 1.hour, end_date: last)

      expect(errors_of(build(:common_house_reservation, start_date: first, end_date: first + 1.hour))).to eq({})
      expect(errors_of(build(:common_house_reservation, resident: taken.resident,
                                                        start_date: last - 30.minutes, end_date: last)))
        .to eq(base: ['Time period is already taken'])
    end
  end

  describe '#period_is_free' do
    it 'is invalid when overlapping with an existing reservation in the same community' do
      community = create(:community)
      resident = create(:resident, community: community)
      create(:common_house_reservation,
             community: community,
             resident: resident,
             start_date: 10.hours.ago,
             end_date: 8.hours.ago)

      overlapping = build(:common_house_reservation,
                          community: community,
                          resident: resident,
                          start_date: 9.hours.ago,
                          end_date: 7.hours.ago)
      expect(overlapping).not_to be_valid
      expect(overlapping.errors[:base]).to include('Time period is already taken')
    end

    it 'is valid when not overlapping with existing reservations' do
      community = create(:community)
      resident = create(:resident, community: community)
      create(:common_house_reservation,
             community: community,
             resident: resident,
             start_date: 10.hours.ago,
             end_date: 8.hours.ago)

      non_overlapping = build(:common_house_reservation,
                              community: community,
                              resident: resident,
                              start_date: 7.hours.ago,
                              end_date: 6.hours.ago)
      expect(non_overlapping).to be_valid
    end

    it 'is valid before an existing reservation, and when one ends exactly as the other starts' do
      community = create(:community)
      resident = create(:resident, community: community)
      taken_start = Time.zone.local(2026, 4, 10, 14, 0)
      create(:common_house_reservation, community: community, resident: resident,
                                        start_date: taken_start, end_date: taken_start + 2.hours)

      earlier = build(:common_house_reservation, community: community, resident: resident,
                                                 start_date: taken_start - 3.hours, end_date: taken_start - 1.hour)
      touching_before = build(:common_house_reservation, community: community, resident: resident,
                                                         start_date: taken_start - 1.hour, end_date: taken_start)
      touching_after = build(:common_house_reservation, community: community, resident: resident,
                                                        start_date: taken_start + 2.hours,
                                                        end_date: taken_start + 3.hours)
      expect([earlier, touching_before, touching_after]).to all(be_valid)
    end
  end

  # Regression test for BUG-4: the push once used only start_date.
  describe 'cache invalidation across months' do
    let(:community) { create(:community) }
    let(:resident) { create(:resident, community: community) }

    before do
      allow(Rails.cache).to receive(:delete)
    end

    it 'invalidates end_date month when it differs from start_date month' do
      # March 1 start — end_of_week is still in March (March 1 is Sunday),
      # so the week-spillover logic does NOT cover April. Only the fix
      # (invalidating end_date's month) would make this pass.
      create(:common_house_reservation,
             community: community, resident: resident,
             start_date: Time.zone.local(2026, 3, 1, 14, 0),
             end_date: Time.zone.local(2026, 4, 30, 16, 0))

      april_key = community.calendar_cache_key(2026, 4)
      expect(Rails.cache).to have_received(:delete).with(april_key)
    end
  end

  describe 'telling the calendar (note_live_update)' do
    let(:community) { create(:community) }
    let(:resident) { create(:resident, community: community) }

    def months_pushed
      RSpec::Mocks.space.proxy_for(Pusher).reset
      pushed = []
      allow(Pusher).to receive(:trigger) { |channel, *| pushed << channel }
      yield
      pushed.select { |channel| channel.include?('-calendar-') }
    end

    def key(year, month)
      community.calendar_cache_key(year, month)
    end

    it 'pushes every month from start to end when it is created' do
      pushed = months_pushed do
        create(:common_house_reservation, community: community, resident: resident,
                                          start_date: Time.zone.local(2026, 3, 15, 14, 0),
                                          end_date: Time.zone.local(2026, 5, 15, 16, 0))
      end

      expect(pushed).to include(key(2026, 3), key(2026, 4), key(2026, 5))
      expect(pushed).not_to include(key(2026, 7))
    end

    it 'pushes the months it no longer spans when only its end moves' do
      reservation = create(:common_house_reservation, community: community, resident: resident,
                                                      start_date: Time.zone.local(2026, 3, 15, 14, 0),
                                                      end_date: Time.zone.local(2026, 7, 15, 16, 0))

      pushed = months_pushed { reservation.update!(end_date: Time.zone.local(2026, 3, 16, 16, 0)) }

      expect(pushed).to include(key(2026, 3), key(2026, 6), key(2026, 7))
    end

    it 'pushes the months it no longer spans when only its start moves' do
      reservation = create(:common_house_reservation, community: community, resident: resident,
                                                      start_date: Time.zone.local(2026, 3, 15, 14, 0),
                                                      end_date: Time.zone.local(2026, 7, 15, 16, 0))

      pushed = months_pushed { reservation.update!(start_date: Time.zone.local(2026, 7, 14, 14, 0)) }

      expect(pushed).to include(key(2026, 3), key(2026, 4), key(2026, 7))
    end

    # The new range can be months the old one never reached. March 2026
    # starts on a Sunday, so its calendar begins on March 1: February 28
    # is not on it, and only the new end tells March. May 15 is on April's
    # and May's calendars, and February 1 is on January's.
    it 'pushes the months it moves into as well as the ones it leaves' do
      reservation = create(:common_house_reservation, community: community, resident: resident,
                                                      start_date: Time.zone.local(2026, 5, 15, 14, 0),
                                                      end_date: Time.zone.local(2026, 5, 15, 16, 0))

      pushed = months_pushed do
        reservation.update!(start_date: Time.zone.local(2026, 2, 28, 18, 0),
                            end_date: Time.zone.local(2026, 3, 1, 10, 0))
      end

      expect(pushed).to contain_exactly(key(2026, 1), key(2026, 2), key(2026, 3), key(2026, 4), key(2026, 5))
    end

    it 'pushes every month it spans when something else about it changes' do
      reservation = create(:common_house_reservation, community: community, resident: resident,
                                                      start_date: Time.zone.local(2026, 3, 15, 14, 0),
                                                      end_date: Time.zone.local(2026, 5, 15, 16, 0))

      pushed = months_pushed { reservation.update!(resident: create(:resident, community: community)) }

      expect(pushed).to include(key(2026, 3), key(2026, 4), key(2026, 5))
    end

    it 'pushes only its own months when the dates do not change' do
      reservation = create(:common_house_reservation, community: community, resident: resident,
                                                      start_date: Time.zone.local(2026, 4, 15, 14, 0),
                                                      end_date: Time.zone.local(2026, 4, 15, 16, 0))

      pushed = months_pushed { reservation.update!(resident: create(:resident, community: community)) }

      # April 1 is on March's six-week calendar too, and a range always
      # includes the first of its months, so March comes along.
      expect(pushed).to contain_exactly(key(2026, 3), key(2026, 4))
    end

    # A month whose calendar lists the booking must be told, or an open
    # tab keeps showing that month without it. The months that list it
    # are asked of CalendarSerializer, with the six weeks
    # CommunitiesController#calendar uses. Each booking crosses the edge
    # of a month's six weeks: March's run March 1 to April 11, April's
    # March 29 to May 9, and May's start on April 26.
    it 'pushes every month whose calendar lists it' do
      bookings = {
        'starts before April' => [[3, 28, 18], [4, 3, 10]],
        'ends as May opens' => [[4, 25, 22], [4, 26, 0]],
        'starts on the last day of March' => [[4, 11, 23], [4, 12, 1]]
      }

      seen = bookings.transform_values do |(start_parts, end_parts)|
        booking = nil
        pushed = months_pushed do
          booking = create(:common_house_reservation, community: community, resident: resident,
                                                      start_date: Time.zone.local(2026, *start_parts),
                                                      end_date: Time.zone.local(2026, *end_parts))
        end
        listed = (1..7).select do |month|
          first = Date.new(2026, month, 1).beginning_of_week(:sunday)
          six_weeks = { start_date: first.to_s, end_date: (first + 41).to_s }
          CalendarSerializer.new(community, params: six_weeks).common_house_reservations_in_range(community).exists?
        end
        booking.destroy!
        { listed: listed, all_pushed: listed.all? { |month| pushed.include?(key(2026, month)) } }
      end

      expect(seen).to eq('starts before April' => { listed: [3, 4], all_pushed: true },
                         'ends as May opens' => { listed: [4, 5], all_pushed: true },
                         'starts on the last day of March' => { listed: [3, 4], all_pushed: true })
    end
  end

  describe '#start_date_is_before_end_date' do
    it 'is invalid when end_date is before start_date' do
      reservation = build(:common_house_reservation, start_date: 1.hour.ago, end_date: 2.hours.ago)
      expect(reservation).not_to be_valid
      expect(reservation.errors[:base]).to include('Start time must occur before end time')
    end

    it 'is valid when start_date is before end_date' do
      reservation = build(:common_house_reservation, start_date: 2.hours.ago, end_date: 1.hour.ago)
      expect(reservation).to be_valid
    end

    # A booking that ends when it starts lasts zero minutes, and it stops no one
    # from booking the common house, so it is refused like an end before
    # its start (#141). The days are an ordinary one and both daylight
    # saving days in Los Angeles.
    it 'is invalid when the booking ends at the moment it starts, and valid when it ends a minute later' do
      [[2026, 4, 12], [2026, 3, 8], [2026, 11, 1]].each do |day|
        start = Time.zone.local(*day, 14, 0)

        same = build(:common_house_reservation, start_date: start, end_date: start)
        expect(same).not_to be_valid
        expect(same.errors[:base]).to eq(['Start time must occur before end time'])
        expect(build(:common_house_reservation, start_date: start, end_date: start + 1.minute)).to be_valid
      end
    end

    # Both time menus left empty save the booking from midnight to
    # midnight, as a notice ("Movie night is cancelled tonight"). That is
    # the one time a booking may be set to end when it starts. Midnight
    # happens once on each daylight saving day in Los Angeles.
    it 'is valid from midnight to midnight in the community zone, on an ordinary day and both daylight saving days' do
      [[2026, 4, 12], [2026, 3, 8], [2026, 11, 1]].each do |day|
        midnight = Time.zone.local(*day)

        expect(build(:common_house_reservation, start_date: midnight, end_date: midnight)).to be_valid
      end
    end

    it 'is invalid when it starts at midnight and ends before that, on an ordinary day and both daylight saving days' do
      [[2026, 4, 12], [2026, 3, 8], [2026, 11, 1]].each do |day|
        midnight = Time.zone.local(*day)
        reservation = build(:common_house_reservation, start_date: midnight, end_date: midnight - 1.hour)

        expect(reservation).not_to be_valid
        expect(reservation.errors[:base]).to eq(['Start time must occur before end time'])
      end
    end

    # 02:30 does not happen in Los Angeles on 2026-03-08, and the API reads
    # 02:30 to 03:30 that day as 03:30 to 03:30 (#125).
    it 'is invalid when a start in the spring-forward gap is moved to its end time' do
      moment = Time.utc(2026, 3, 8, 10, 30)
      reservation = build(:common_house_reservation, start_date: moment, end_date: moment)

      expect(reservation).not_to be_valid
      expect(reservation.errors[:base]).to eq(['Start time must occur before end time'])
    end

    # A task or a job has no zone of its own; the app's zone here is Los
    # Angeles, and the community is in New York.
    it 'reads midnight in the community zone, not the app zone' do
      community = create(:community, timezone: 'America/New_York')
      resident = create(:resident, community: community)
      new_york = ActiveSupport::TimeZone['America/New_York']

      valid = [new_york.local(2026, 3, 8), Time.zone.local(2026, 3, 8)].map do |moment|
        build(:common_house_reservation, community: community, resident: resident,
                                         start_date: moment, end_date: moment).valid?
      end

      expect(valid).to eq([true, false])
    end

    # A change of only one of the two times can also make them equal.
    it 'refuses a change of only the start, or only the end, that makes the booking end when it starts' do
      start = Time.zone.local(2026, 4, 12, 14, 0)
      reservation = create(:common_house_reservation, start_date: start, end_date: start + 1.hour)

      expect(reservation.update(start_date: start + 1.hour)).to be(false)
      expect(reservation.errors[:base]).to eq(['Start time must occur before end time'])
      reservation.reload
      expect(reservation.update(end_date: start)).to be(false)
      expect(reservation.errors[:base]).to eq(['Start time must occur before end time'])
      expect(reservation.reload).to have_attributes(start_date: start, end_date: start + 1.hour)
    end

    # Production has one booking from before #141 that ends when it
    # starts, not at midnight: 1117. The rule must not stop anyone from
    # saving it as it is, with a new title, or with the same times sent
    # back, as the edit form does. It runs only when a time is set or
    # changed. The times here are those of booking 1117.
    describe 'a booking saved before #141 that ends when it starts, not at midnight' do
      let(:moment) { Time.zone.local(2023, 12, 11, 17, 30) }
      let(:reservation) do
        create(:common_house_reservation, title: 'Finance Committee', start_date: moment, end_date: moment + 1.hour)
          .tap { |reservation| reservation.update_columns(end_date: moment) }
      end

      it 'saves a new title, and the same times sent back' do
        expect(reservation.update(title: 'Finance Committee [Zoom]')).to be(true)
        expect(reservation.update(start_date: Time.zone.local(2023, 12, 11, 17, 30),
                                  end_date: Time.zone.local(2023, 12, 11, 17, 30), title: 'Finance')).to be(true)

        expect(reservation.reload).to have_attributes(title: 'Finance', start_date: moment, end_date: moment)
      end

      it 'refuses a move to other times that end when they start, on an ordinary day and both daylight saving days' do
        [[2026, 4, 12], [2026, 3, 8], [2026, 11, 1]].each do |day|
          other = Time.zone.local(*day, 14, 0)

          expect(reservation.update(start_date: other, end_date: other)).to be(false)
          expect(reservation.errors[:base]).to eq(['Start time must occur before end time'])
          expect(reservation.reload).to have_attributes(start_date: moment, end_date: moment)
        end
      end

      it 'saves a later end, or an earlier start' do
        expect(reservation.update(end_date: moment + 1.hour)).to be(true)
        expect(reservation.reload).to have_attributes(start_date: moment, end_date: moment + 1.hour)

        reservation.update_columns(end_date: moment)
        expect(reservation.update(start_date: moment - 1.hour)).to be(true)
        expect(reservation.reload).to have_attributes(start_date: moment - 1.hour, end_date: moment)
      end
    end

    # An end before its start is refused on every save, even one that does
    # not change the times. No such booking is in production.
    it 'refuses any save of a booking that ends before it starts' do
      moment = Time.zone.local(2023, 12, 11, 17, 30)
      reservation = create(:common_house_reservation, start_date: moment, end_date: moment + 1.hour)
      reservation.update_columns(end_date: moment - 1.minute)

      expect(reservation.update(title: 'Renamed')).to be(false)
      expect(reservation.errors[:base]).to eq(['Start time must occur before end time'])
    end
  end
end
