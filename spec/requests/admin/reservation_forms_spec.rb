# frozen_string_literal: true

require 'rails_helper'

# The admin can edit and delete guest-room and common-house reservations,
# next to the API. The API's rules (no two guest-room bookings on one day,
# no overlapping common-house periods) are pinned in spec/requests/api/v1;
# this pins them on the admin forms, and checks the calendar afterward
# against a real cache.
RSpec.describe 'Admin reservation forms' do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:admin_user) { create(:admin_user, community: community, superuser: true) }
  let(:resident) { create(:resident, community: community, unit: unit, multiplier: 2) }
  let(:token) { resident.keys.first.token }

  around do |example|
    original_store = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    example.run
    Rails.cache = original_store
  end

  before do
    host! 'admin.example.com'
    sign_in admin_user
  end

  def calendar_starts(key)
    host! 'www.example.com'
    get "/api/v1/communities/#{community.id}/calendar/2026-04-15", params: { token: token }
    host! 'admin.example.com'
    sign_in admin_user # the admin session does not survive the host switch
    response.parsed_body[key].map { |row| row['start'].to_s[0, 10] }
  end

  describe 'guest room' do
    let!(:reservation) do
      create(:guest_room_reservation, community: community, resident: resident, date: Date.new(2026, 4, 10))
    end

    it 'moves the booking to another day, and the calendar follows' do
      expect(calendar_starts('guest_room_reservations')).to include('2026-04-10')

      patch "/guest_room_reservations/#{reservation.id}", params: { guest_room_reservation: { date: '2026-04-12' } }

      expect(response).to redirect_to("/guest_room_reservations/#{reservation.id}")
      expect(calendar_starts('guest_room_reservations')).to eq(['2026-04-12'])
    end

    it 'refuses a day that is already booked, and says so' do
      create(:guest_room_reservation, community: community, resident: resident, date: Date.new(2026, 4, 12))

      patch "/guest_room_reservations/#{reservation.id}", params: { guest_room_reservation: { date: '2026-04-12' } }

      expect(reservation.reload.date).to eq(Date.new(2026, 4, 10))
      expect(response.body).to include('already been taken')
    end

    it 'deletes the booking, and the calendar drops it' do
      delete "/guest_room_reservations/#{reservation.id}"

      expect(GuestRoomReservation.exists?(reservation.id)).to be(false)
      expect(calendar_starts('guest_room_reservations')).to be_empty
    end
  end

  describe 'common house' do
    let!(:reservation) do
      create(:common_house_reservation, community: community, resident: resident,
                                        start_date: Time.zone.local(2026, 4, 10, 18),
                                        end_date: Time.zone.local(2026, 4, 10, 21))
    end

    it 'moves the period, and the calendar follows' do
      expect(calendar_starts('common_house_reservations')).to include('2026-04-10')

      patch "/common_house_reservations/#{reservation.id}",
            params: { common_house_reservation: { start_date: '2026-04-12 18:00', end_date: '2026-04-12 21:00' } }

      expect(response).to redirect_to("/common_house_reservations/#{reservation.id}")
      expect(calendar_starts('common_house_reservations')).to eq(['2026-04-12'])
    end

    it 'refuses a period that overlaps another booking, and says so' do
      create(:common_house_reservation, community: community, resident: resident,
                                        start_date: Time.zone.local(2026, 4, 12, 18),
                                        end_date: Time.zone.local(2026, 4, 12, 21))

      patch "/common_house_reservations/#{reservation.id}",
            params: { common_house_reservation: { start_date: '2026-04-12 19:00', end_date: '2026-04-12 20:00' } }

      expect(reservation.reload.start_date.to_date).to eq(Date.new(2026, 4, 10))
      expect(response.body).to include('Time period is already taken')
    end

    it 'refuses an end before the start, and says so' do
      patch "/common_house_reservations/#{reservation.id}",
            params: { common_house_reservation: { start_date: '2026-04-12 21:00', end_date: '2026-04-12 18:00' } }

      expect(reservation.reload.start_date.to_date).to eq(Date.new(2026, 4, 10))
      expect(response.body).to include('Start time must occur before end time')
    end

    it 'deletes the booking, and the calendar drops it' do
      delete "/common_house_reservations/#{reservation.id}"

      expect(CommonHouseReservation.exists?(reservation.id)).to be(false)
      expect(calendar_starts('common_house_reservations')).to be_empty
    end
  end
end
