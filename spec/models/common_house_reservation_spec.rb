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

    it 'pushes only its own months when the dates do not change' do
      reservation = create(:common_house_reservation, community: community, resident: resident,
                                                      start_date: Time.zone.local(2026, 4, 15, 14, 0),
                                                      end_date: Time.zone.local(2026, 4, 15, 16, 0))

      pushed = months_pushed { reservation.update!(resident: create(:resident, community: community)) }

      # April 1 is on March's six-week calendar too, and a range always
      # includes the first of its months, so March comes along.
      expect(pushed).to contain_exactly(key(2026, 3), key(2026, 4))
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
  end
end
