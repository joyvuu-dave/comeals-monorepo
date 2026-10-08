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
  describe 'validations' do
    it 'is valid with valid attributes' do
      event = build(:event)
      expect(event).to be_valid
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
      expect(errors_of(build(:event, start_date: first, end_date: last))).to eq({})
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
      event = build(:event, start_date: 2.hours.ago, end_date: 1.hour.ago, allday: false)
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
      create(:event, community: community,
                     start_date: Time.zone.local(2026, 3, 1, 14, 0),
                     end_date: Time.zone.local(2026, 4, 30, 14, 0))

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

    it 'pushes every month from start to end when it is created' do
      pushed = months_pushed do
        create(:event, community: community, start_date: Time.zone.local(2026, 3, 15, 14, 0),
                       end_date: Time.zone.local(2026, 5, 15, 16, 0))
      end

      expect(pushed).to include(key(2026, 3), key(2026, 4), key(2026, 5))
      expect(pushed).not_to include(key(2026, 7))
    end

    it 'pushes the months it no longer spans when only its end moves' do
      event = create(:event, community: community, start_date: Time.zone.local(2026, 3, 15, 14, 0),
                             end_date: Time.zone.local(2026, 7, 15, 16, 0))

      pushed = months_pushed { event.update!(end_date: Time.zone.local(2026, 3, 16, 16, 0)) }

      expect(pushed).to include(key(2026, 3), key(2026, 6), key(2026, 7))
    end

    it 'pushes the months it no longer spans when only its start moves' do
      event = create(:event, community: community, start_date: Time.zone.local(2026, 3, 15, 14, 0),
                             end_date: Time.zone.local(2026, 7, 15, 16, 0))

      pushed = months_pushed { event.update!(start_date: Time.zone.local(2026, 7, 14, 14, 0)) }

      expect(pushed).to include(key(2026, 3), key(2026, 4), key(2026, 7))
    end

    # The new range can be months the old one never reached. March 2026
    # starts on a Sunday, so its calendar begins on March 1: February 28
    # is not on it, and only the new end tells March. May 15 is on April's
    # and May's calendars, and February 1 is on January's.
    it 'pushes the months it moves into as well as the ones it leaves' do
      event = create(:event, community: community, start_date: Time.zone.local(2026, 5, 15, 14, 0),
                             end_date: Time.zone.local(2026, 5, 15, 16, 0))

      pushed = months_pushed do
        event.update!(start_date: Time.zone.local(2026, 2, 28, 18, 0),
                      end_date: Time.zone.local(2026, 3, 1, 10, 0))
      end

      expect(pushed).to contain_exactly(key(2026, 1), key(2026, 2), key(2026, 3), key(2026, 4), key(2026, 5))
    end

    it 'pushes every month it spans when something else about it changes' do
      event = create(:event, community: community, start_date: Time.zone.local(2026, 3, 15, 14, 0),
                             end_date: Time.zone.local(2026, 5, 15, 16, 0))

      pushed = months_pushed { event.update!(title: 'Renamed') }

      expect(pushed).to include(key(2026, 3), key(2026, 4), key(2026, 5))
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

    it 'is invalid when it starts at midnight and ends before that, on an ordinary day and both daylight saving days' do
      [[2026, 4, 15], [2026, 3, 8], [2026, 11, 1]].each do |day|
        midnight = Time.zone.local(*day)
        event = build(:event, start_date: midnight, end_date: midnight - 1.hour, allday: false)

        expect(event).not_to be_valid
        expect(event.errors[:base]).to eq(['Start time must occur before end time'])
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
    # not change the times. No such event is in production.
    it 'refuses any save of an event that ends before it starts' do
      moment = Time.zone.local(2022, 7, 26, 8, 0)
      event = create(:event, start_date: moment, end_date: moment + 1.hour, allday: false)
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
