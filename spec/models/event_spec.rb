# frozen_string_literal: true

# == Schema Information
#
# Table name: events
#
#  id           :bigint           not null, primary key
#  allday       :boolean          default(FALSE), not null
#  description  :string           default(""), not null
#  end_date     :datetime
#  start_date   :datetime         not null
#  title        :string           not null
#  created_at   :datetime         not null
#  updated_at   :datetime         not null
#  community_id :bigint           not null
#
# Indexes
#
#  index_events_on_start_date  (start_date)
#
# Foreign Keys
#
#  fk_rails_...  (community_id => communities.id)
#

require 'rails_helper'

RSpec.describe Event do
  include ActiveSupport::Testing::TimeHelpers

  describe 'validations' do
    it 'is valid with valid attributes' do
      event = build(:event)
      expect(event).to be_valid
    end

    # The factory's event must be one day at any hour a spec runs, in any
    # zone. Its times were 49 to 48 hours ago, which ran past midnight
    # when a spec ran from 00:00 to 00:59.
    it 'is valid as the factory makes it, at any hour and in a zone far from the app zone' do
      [Time.zone.local(2026, 4, 12, 23, 30), Time.zone.local(2026, 4, 13, 0, 30)].each do |now|
        travel_to(now) { expect(build(:event)).to be_valid }
      end
      create(:community, timezone: 'Europe/Paris')
      expect(build(:event)).to be_valid
    end

    it 'validates presence of title' do
      event = build(:event, title: nil)
      expect(event).not_to be_valid
      expect(event.errors[:title]).to include("can't be blank")
    end

    it 'validates presence of start_date' do
      event = build(:event, start_date: nil, allday: true)
      expect(event).not_to be_valid
      expect(event.errors[:start_date]).to include("can't be blank")
    end
  end

  # The admin forms and a task save through the model, not the API's
  # parser, so the model refuses a time the database cannot store
  # (StorableTime). Before, PostgreSQL refused it on save: a 500.
  describe 'a time the database cannot store' do
    let(:first) { StorableTime::TIMESTAMPS.begin }
    let(:last) { StorableTime::TIMESTAMPS.end - Rational(1, 1_000_000) }
    let(:refused) { ['is not a date the database can store'] }

    def errors_of(event)
      event.validate
      event.errors.to_hash
    end

    it 'refuses a start a second before the first instant, or an end a second after the last, under that time' do
      expect(errors_of(build(:event, start_date: first - 1.second, end_date: first + 1.hour)))
        .to eq(start_date: refused)
      expect(errors_of(build(:event, start_date: last - 1.hour, end_date: last + 1.second)))
        .to eq(end_date: refused)
    end

    it 'takes the first and the last instant, and an all-day event with no end' do
      expect(errors_of(build(:event, start_date: first, end_date: first + 1.hour))).to eq({})
      expect(errors_of(build(:event, start_date: last - 1.hour, end_date: last))).to eq({})
      expect(errors_of(build(:event, allday: true, start_date: first, end_date: nil))).to eq({})
    end
  end

  describe '#end_date_or_allday' do
    it 'is invalid without end_date when allday is false' do
      event = build(:event, end_date: nil, allday: false)
      expect(event).not_to be_valid
      expect(event.errors[:base]).to include('Event must end or be all day')
    end

    it 'is valid without end_date when allday is true' do
      event = build(:event, end_date: nil, allday: true)
      expect(event).to be_valid
    end

    it 'is valid with end_date when allday is false' do
      # Fixed times: two hours ago to one hour ago runs past midnight when
      # a spec runs from 01:00 to 01:59, and an event is one day (#154).
      event = build(:event, start_date: Time.zone.local(2026, 4, 15, 14), end_date: Time.zone.local(2026, 4, 15, 15),
                            allday: false)
      expect(event).to be_valid
    end
  end

  # Regression test for BUG-4: the push once used only start_date, leaving
  # the end_date month's calendar cache stale for multi-month events.
  describe 'cache invalidation across months' do
    let(:community) { create(:community) }

    before do
      allow(Rails.cache).to receive(:delete)
    end

    it 'invalidates end_date month when it differs from start_date month' do
      event_without_the_model(community: community, start_date: Time.zone.local(2026, 3, 1, 14, 0),
                              end_date: Time.zone.local(2026, 4, 30, 14, 0)).destroy!

      april_key = community.calendar_cache_key(2026, 4)
      expect(Rails.cache).to have_received(:delete).with(april_key)
    end

    it 'invalidates old start_date month when start_date moves to a different month' do
      event = create(:event, community: community,
                             start_date: Time.zone.local(2026, 3, 15, 14, 0),
                             end_date: Time.zone.local(2026, 3, 15, 16, 0))

      # Track only the cache deletions from the update, not the create
      deleted_keys = []
      allow(Rails.cache).to receive(:delete) { |key| deleted_keys << key }

      event.update!(start_date: Time.zone.local(2026, 5, 15, 14, 0),
                    end_date: Time.zone.local(2026, 5, 15, 16, 0))

      march_key = community.calendar_cache_key(2026, 3)
      expect(deleted_keys).to include(march_key)
    end
  end

  # Every month from start to end is pushed on every save; when the dates
  # move, the months of the old range too, or a screen showing the old
  # month keeps the event where it no longer is.
  describe 'telling the calendar (note_live_update)' do
    let(:community) { create(:community) }

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

    it 'pushes every month from start to end when it is deleted' do
      event = event_without_the_model(community: community, start_date: Time.zone.local(2026, 3, 15, 14, 0),
                                      end_date: Time.zone.local(2026, 5, 15, 16, 0))

      pushed = months_pushed { event.destroy! }

      expect(pushed).to include(key(2026, 3), key(2026, 4), key(2026, 5))
      expect(pushed).not_to include(key(2026, 7))
    end

    # The console can save without the validations, and so without the
    # one-day rule (#154). The database refuses such an end too, unless
    # its one-day trigger is turned off, as a repair in psql could do.
    # Then the months up to the new end must be told too, not only the
    # start's.
    it 'pushes every month up to a new end saved without the validations' do
      event = create(:event, community: community, start_date: Time.zone.local(2026, 3, 15, 14, 0),
                             end_date: Time.zone.local(2026, 3, 15, 16, 0))
      event.end_date = Time.zone.local(2026, 5, 15, 16, 0)

      pushed = months_pushed { with_one_day_trigger_off(:events) { event.save(validate: false) } }

      expect(pushed).to include(key(2026, 4), key(2026, 5))
    end

    it 'pushes the months it no longer spans when only its end moves' do
      event = event_without_the_model(community: community, start_date: Time.zone.local(2026, 3, 15, 14, 0),
                                      end_date: Time.zone.local(2026, 7, 15, 16, 0))

      pushed = months_pushed { event.update!(end_date: Time.zone.local(2026, 3, 15, 16, 0)) }

      expect(pushed).to include(key(2026, 3), key(2026, 6), key(2026, 7))
    end

    it 'pushes the months it no longer spans when only its start moves' do
      event = event_without_the_model(community: community, start_date: Time.zone.local(2026, 3, 15, 14, 0),
                                      end_date: Time.zone.local(2026, 7, 15, 16, 0))

      pushed = months_pushed { event.update!(start_date: Time.zone.local(2026, 7, 15, 14, 0)) }

      expect(pushed).to include(key(2026, 3), key(2026, 4), key(2026, 7))
    end

    # The new range can be months the old one never reached. February 1,
    # the first day of the new month, is on January's calendar too.
    # February 28 is not on March's: March 2026 starts on a Sunday, so its
    # calendar begins on March 1. May 1 is on April's calendar.
    it 'pushes the months it moves into as well as the ones it leaves' do
      event = create(:event, community: community, start_date: Time.zone.local(2026, 5, 15, 14, 0),
                             end_date: Time.zone.local(2026, 5, 15, 16, 0))

      pushed = months_pushed do
        event.update!(start_date: Time.zone.local(2026, 2, 28, 18, 0),
                      end_date: Time.zone.local(2026, 2, 28, 21, 0))
      end

      expect(pushed).to contain_exactly(key(2026, 1), key(2026, 2), key(2026, 4), key(2026, 5))
    end

    it 'pushes only its own months when the dates do not change' do
      event = create(:event, community: community, start_date: Time.zone.local(2026, 4, 15, 14, 0),
                             end_date: Time.zone.local(2026, 4, 15, 16, 0))

      pushed = months_pushed { event.update!(title: 'Renamed') }

      # April 1 is on March's six-week calendar too, and a range always
      # includes the first of its months, so March comes along.
      expect(pushed).to contain_exactly(key(2026, 3), key(2026, 4))
    end
  end

  describe '#start_date_is_before_end_date' do
    it 'is invalid when end_date is before start_date' do
      event = build(:event, start_date: 1.hour.ago, end_date: 2.hours.ago, allday: false)
      expect(event).not_to be_valid
      expect(event.errors[:base]).to include('Start time must occur before end time')
    end

    # An event that ends when it starts lasts zero minutes, so it is refused
    # like an end before its start (#141). The days are an ordinary one
    # and both daylight saving days in Los Angeles.
    it 'is invalid when the event ends at the moment it starts, and valid when it ends a minute later' do
      [[2026, 4, 15], [2026, 3, 8], [2026, 11, 1]].each do |day|
        start = Time.zone.local(*day, 14, 0)

        same = build(:event, start_date: start, end_date: start, allday: false)
        expect(same).not_to be_valid
        expect(same.errors[:base]).to eq(['Start time must occur before end time'])
        expect(build(:event, start_date: start, end_date: start + 1.minute, allday: false)).to be_valid
      end
    end

    # Both time menus left empty save the event from midnight to midnight,
    # as a notice ("Movie night is cancelled tonight"). That is the one
    # time an event may be set to end when it starts. Midnight happens
    # once on each daylight saving day in Los Angeles.
    it 'is valid from midnight to midnight in the community zone, on an ordinary day and both daylight saving days' do
      [[2026, 4, 15], [2026, 3, 8], [2026, 11, 1]].each do |day|
        midnight = Time.zone.local(*day)

        expect(build(:event, start_date: midnight, end_date: midnight, allday: false)).to be_valid
      end
    end

    # The end is on the day before, so the one-day rule refuses it too.
    it 'is invalid when it starts at midnight and ends before that, on an ordinary day and both daylight saving days' do
      [[2026, 4, 15], [2026, 3, 8], [2026, 11, 1]].each do |day|
        midnight = Time.zone.local(*day)
        event = build(:event, start_date: midnight, end_date: midnight - 1.hour, allday: false)

        expect(event).not_to be_valid
        expect(event.errors[:base])
          .to eq(['Start time must occur before end time', 'An event must start and end on the same day.'])
      end
    end

    # 02:30 does not happen in Los Angeles on 2026-03-08, and the API reads
    # 02:30 to 03:30 that day as 03:30 to 03:30 (#125).
    it 'is invalid when a start in the spring-forward gap is moved to its end time' do
      moment = Time.utc(2026, 3, 8, 10, 30)
      event = build(:event, start_date: moment, end_date: moment, allday: false)

      expect(event).not_to be_valid
      expect(event.errors[:base]).to eq(['Start time must occur before end time'])
    end

    # A task or a job has no zone of its own; the app's zone here is Los
    # Angeles, and the community is in New York.
    it 'reads midnight in the community zone, not the app zone' do
      community = create(:community, timezone: 'America/New_York')
      new_york = ActiveSupport::TimeZone['America/New_York']

      valid = [new_york.local(2026, 3, 8), Time.zone.local(2026, 3, 8)].map do |moment|
        build(:event, community: community, start_date: moment, end_date: moment, allday: false).valid?
      end

      expect(valid).to eq([true, false])
    end

    # A change of only one of the two times can also make them equal.
    it 'refuses a change of only the start, or only the end, that makes the event end when it starts' do
      start = Time.zone.local(2026, 4, 15, 14, 0)
      event = create(:event, start_date: start, end_date: start + 1.hour, allday: false)

      expect(event.update(start_date: start + 1.hour)).to be(false)
      expect(event.errors[:base]).to eq(['Start time must occur before end time'])
      event.reload
      expect(event.update(end_date: start)).to be(false)
      expect(event.errors[:base]).to eq(['Start time must occur before end time'])
      expect(event.reload).to have_attributes(start_date: start, end_date: start + 1.hour)
    end

    # All day hides the times, so an all-day event may end when it starts.
    # Turning all day off makes those times count, so the rule runs then.
    it 'refuses turning all day off when the event would then end when it starts' do
      start = Time.zone.local(2026, 4, 15, 14, 0)
      event = create(:event, start_date: start, end_date: start, allday: true)

      expect(event.update(allday: false)).to be(false)
      expect(event.errors[:base]).to eq(['Start time must occur before end time'])
      expect(event.reload.allday).to be(true)
    end

    # Production has three events from before #141 that end when they
    # start, not at midnight: 143, 489 and 1056. The rule must not stop
    # anyone from saving such an event as it is, with a new title, or with
    # the same times sent back, as the edit form does. It runs only when a
    # time is set or changed. The times here are those of event 1056.
    describe 'an event saved before #141 that ends when it starts, not at midnight' do
      let(:moment) { Time.zone.local(2022, 7, 26, 8, 0) }
      let(:event) do
        create(:event, title: 'WM Bulk Pick-up', start_date: moment, end_date: moment + 1.hour, allday: false)
          .tap { |event| event.update_columns(end_date: moment) }
      end

      it 'saves a new title, and the same times sent back' do
        expect(event.update(title: 'WM Bulk Pick-up moved')).to be(true)
        expect(event.update(start_date: Time.zone.local(2022, 7, 26, 8, 0),
                            end_date: Time.zone.local(2022, 7, 26, 8, 0), description: 'Bins out by 7')).to be(true)

        expect(event.reload).to have_attributes(title: 'WM Bulk Pick-up moved', description: 'Bins out by 7',
                                                start_date: moment, end_date: moment)
      end

      it 'refuses a move to other times that end when they start, on an ordinary day and both daylight saving days' do
        [[2026, 4, 15], [2026, 3, 8], [2026, 11, 1]].each do |day|
          other = Time.zone.local(*day, 14, 0)

          expect(event.update(start_date: other, end_date: other)).to be(false)
          expect(event.errors[:base]).to eq(['Start time must occur before end time'])
          expect(event.reload).to have_attributes(start_date: moment, end_date: moment)
        end
      end

      it 'saves a later end, or an earlier start' do
        expect(event.update(end_date: moment + 1.hour)).to be(true)
        expect(event.reload).to have_attributes(start_date: moment, end_date: moment + 1.hour)

        event.update_columns(end_date: moment)
        expect(event.update(start_date: moment - 1.hour)).to be(true)
        expect(event.reload).to have_attributes(start_date: moment - 1.hour, end_date: moment)
      end
    end

    # An end before its start is refused on every save, even one that does
    # not change the times. Since #149 the database refuses such a row
    # too, so the CHECK is dropped for this example (rolled back with the
    # transaction).
    it 'refuses any save of an event that ends before it starts' do
      moment = Time.zone.local(2022, 7, 26, 8, 0)
      event = create(:event, start_date: moment, end_date: moment + 1.hour, allday: false)
      ActiveRecord::Base.connection.remove_check_constraint(:events, name: 'events_end_not_before_start')
      event.update_columns(end_date: moment - 1.minute)

      expect(event.update(title: 'Renamed')).to be(false)
      expect(event.errors[:base]).to eq(['Start time must occur before end time'])
    end

    it 'skips validation when allday is true' do
      event = build(:event, start_date: 1.hour.ago, end_date: 2.hours.ago, allday: true)
      expect(event).to be_valid
    end

    it 'reports a missing start when there is an end, instead of comparing against nothing' do
      event = build(:event, start_date: nil, end_date: Time.zone.local(2026, 4, 15, 16, 0))

      expect(event).not_to be_valid
      expect(event.errors[:start_date]).to be_present
      expect(event.errors[:base]).to be_empty
    end

    # Not all day, so only the blank-end guard keeps the comparison from
    # running on nil; the one message is the one #end_date_or_allday adds.
    it 'skips the comparison when end_date is blank' do
      event = build(:event, start_date: 1.hour.ago, end_date: nil, allday: false)

      expect { event.valid? }.not_to raise_error
      expect(event.errors[:base]).to eq(['Event must end or be all day'])
    end
  end

  # The app's forms give an event one day and two times. Admin, a task or
  # the console could give it an end on a later day, and the edit form
  # could not save such an event again: it keeps only the start day
  # (#154). So an event must start and end on the same day. The day is
  # read in the community's zone, never in UTC: 5 PM in Los Angeles is
  # already the next day in UTC, and that mistake made #154's first
  # counts wrong. The days are an ordinary one and both daylight saving
  # days in Los Angeles.
  describe '#starts_and_ends_on_one_day' do
    let(:days) { [[2026, 4, 15], [2026, 3, 8], [2026, 11, 1]] }
    let(:refused) { ['An event must start and end on the same day.'] }

    def timed(start, finish)
      build(:event, start_date: start, end_date: finish, allday: false)
    end

    it 'takes an event from 00:30 to 23:30, which is two days in UTC' do
      days.each do |day|
        start = Time.zone.local(*day, 0, 30)
        finish = Time.zone.local(*day, 23, 30)

        expect(start.utc.to_date).not_to eq(finish.utc.to_date)
        expect(timed(start, finish)).to be_valid
      end
    end

    # 23:00 to 00:30 is one day in UTC: 06:00 to 07:30, or 07:00 to
    # 08:30 in winter.
    it 'refuses an event that runs past midnight, even when UTC sees one day' do
      days.each do |day|
        start = Time.zone.local(*day, 23, 0)
        finish = start + 90.minutes

        expect(start.utc.to_date).to eq(finish.utc.to_date)
        event = timed(start, finish)
        expect(event).not_to be_valid
        expect(event.errors[:base]).to eq(refused)
      end
    end

    # Midnight is the first moment of the next day, so an event that ends
    # at midnight ends on the next day. The time menus cannot make one:
    # they run from 8 AM to 10 PM.
    it 'refuses an event that ends at the next midnight' do
      days.each do |day|
        next_day = Date.new(*day) + 1
        event = timed(Time.zone.local(*day, 22, 0), Time.zone.local(next_day.year, next_day.month, next_day.day))

        expect(event).not_to be_valid
        expect(event.errors[:base]).to eq(refused)
      end
    end

    # A task or a job has no zone of its own; the app's zone here is Los
    # Angeles, and the community is in New York. 20:00 to 22:00 in Los
    # Angeles is 23:00 to 01:00 in New York, and 23:00 to 00:30 is 02:00
    # to 03:30.
    it 'reads the day in the community zone, not the app zone' do
      community = create(:community, timezone: 'America/New_York')
      evening = Time.zone.local(2026, 4, 15, 20, 0)
      late = Time.zone.local(2026, 4, 15, 23, 0)

      valid = [[evening, evening + 2.hours], [late, late + 90.minutes]].map do |start, finish|
        build(:event, community: community, start_date: start, end_date: finish, allday: false).valid?
      end

      expect(valid).to eq([false, true])
    end

    # All day hides the end, so an all-day event has no days to compare.
    # The API saves one with no end; the admin form can keep an end.
    it 'does not apply to an all-day event' do
      start = Time.zone.local(2026, 4, 15)

      expect(build(:event, allday: true, start_date: start, end_date: nil)).to be_valid
      expect(build(:event, allday: true, start_date: start, end_date: start + 3.days)).to be_valid
    end

    # The rule runs only when a save sets or changes the times, or turns
    # all day off, the same writes the events_one_day trigger checks. A
    # change of the community's zone can leave an event that ends on a
    # later day: 20:00 to 23:00 in Los Angeles is 23:00 to 02:00 in New
    # York. Nobody chose those times. Until #173 the rule ran on every
    # save, so no save of such an event was taken, not even a new title,
    # and nobody could edit it at all. A save that moves its times, or
    # turns all day off, is still refused.
    it 'takes a new title for an event that ends on a later day only because the zone changed' do
      events = days.map do |day|
        start = Time.zone.local(*day, 20, 0)
        create(:event, start_date: start, end_date: start + 3.hours, allday: false)
      end
      Community.first!.update!(timezone: 'America/New_York')

      saved = events.map { |event| described_class.find(event.id).update(title: 'Renamed') }
      expect(saved).to eq([true, true, true])

      moved = described_class.find(events.first.id)
      expect(moved.update(start_date: moved.start_date + 30.minutes)).to be(false)
      expect(moved.errors[:base]).to eq(refused)

      moved.reload.update_columns(allday: true)
      expect(moved.update(allday: false)).to be(false)
      expect(moved.errors[:base]).to eq(refused)
    end

    it 'gives both messages for an end on the day before the start' do
      start = Time.zone.local(2026, 4, 16, 1, 0)

      event = timed(start, start - 2.hours)

      expect(event).not_to be_valid
      expect(event.errors[:base]).to eq(['Start time must occur before end time', *refused])
    end
  end

  # The database refuses an end before the start even when the model did
  # not see it: another write changed the row after the model checked it
  # (#149). Then save answers false with the model's own message, as it
  # does when the model sees the other write in time, instead of raising
  # (an error page in admin).
  describe 'a save the database refuses' do
    let(:start) { Time.zone.local(2026, 4, 15, 18, 0) }

    # A console or a task beside a request: two copies of one event. Each
    # changes one time and passes its own check, and Rails writes only the
    # column that changed, so the row would end before it starts.
    it 'answers in words when another copy moved the start past this copy\'s new end' do
      event = create(:event, start_date: start, end_date: start + 3.hours, allday: false)
      first = described_class.find(event.id)
      second = described_class.find(event.id)
      first.update!(start_date: start + 2.hours)

      expect(second.update(end_date: start + 1.hour)).to be(false)
      expect(second.errors[:base]).to eq(['Start time must occur before end time'])
      expect(event.reload).to have_attributes(start_date: start + 2.hours, end_date: start + 3.hours)
    end

    # Two copies again. One moves the event to the day before. The other,
    # loaded earlier, moves only its end, later on the old day. Each is
    # one day as it sees it, and the row would run over two days.
    it 'answers in words when another copy moved the event to an earlier day' do
      event = create(:event, start_date: start, end_date: start + 3.hours, allday: false)
      first = described_class.find(event.id)
      second = described_class.find(event.id)
      first.update!(start_date: start - 1.day, end_date: start - 1.day + 3.hours)

      expect(second.update(end_date: start + 4.hours)).to be(false)
      expect(second.errors[:base]).to eq(['An event must start and end on the same day.'])
      expect(event.reload).to have_attributes(start_date: start - 1.day, end_date: start - 1.day + 3.hours)
    end

    it 'raises for a database rule it has no words for' do
      ActiveRecord::Base.connection.add_check_constraint(:events, "title <> 'spec'", name: 'spec_only')

      expect { create(:event, title: 'spec') }.to raise_error(ActiveRecord::CheckViolation, /spec_only/)
    end
  end

  # Issue #139. Every true/false column is NOT NULL, and without this
  # check a nil would reach the database as a 500. Nothing sends a nil today:
  # the API reads all_day as true or false, and the admin box sends 0 or
  # 1. The model refuses it anyway, with a sentence.
  describe 'the allday column' do
    it 'refuses a nil with a sentence, and keeps the stored value' do
      record = create(:event)
      stored = record.allday
      record.allday = nil

      expect(record.save).to be(false)
      expect(record.errors.full_messages).to eq(['Allday must be true or false'])
      expect(record.reload.allday).to eq(stored)
    end
  end
end
