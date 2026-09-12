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

    it 'is valid when start_date is before end_date' do
      event = build(:event, start_date: 2.hours.ago, end_date: 1.hour.ago, allday: false)
      expect(event).to be_valid
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

    it 'skips validation when end_date is blank' do
      event = build(:event, start_date: 1.hour.ago, end_date: nil, allday: true)
      expect(event).to be_valid
    end
  end
end
