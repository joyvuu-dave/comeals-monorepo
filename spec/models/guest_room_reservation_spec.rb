# frozen_string_literal: true

# == Schema Information
#
# Table name: guest_room_reservations
#
#  id           :bigint           not null, primary key
#  date         :date             not null
#  created_at   :datetime         not null
#  updated_at   :datetime         not null
#  community_id :bigint           not null
#  resident_id  :bigint           not null
#
# Indexes
#
#  index_guest_room_reservations_on_date         (date) UNIQUE
#  index_guest_room_reservations_on_resident_id  (resident_id)
#
# Foreign Keys
#
#  fk_rails_...  (community_id => communities.id)
#  fk_rails_...  (resident_id => residents.id)
#

require 'rails_helper'

RSpec.describe GuestRoomReservation do
  describe 'validations' do
    it 'is valid with valid attributes' do
      reservation = build(:guest_room_reservation)
      expect(reservation).to be_valid
    end

    it 'validates presence of resident' do
      reservation = build(:guest_room_reservation, resident: nil)
      expect(reservation).not_to be_valid
      expect(reservation.errors[:resident]).to include('must exist')
    end

    it 'validates presence of date' do
      reservation = build(:guest_room_reservation, date: nil)
      expect(reservation).not_to be_valid
      expect(reservation.errors[:date]).to include("can't be blank")
    end
  end

  describe 'uniqueness of date per community' do
    it 'is invalid when date is already taken for the same community' do
      community = create(:community)
      resident = create(:resident, community: community)
      create(:guest_room_reservation,
             community: community,
             resident: resident,
             date: Date.new(2026, 4, 1))

      duplicate = build(:guest_room_reservation,
                        community: community,
                        resident: resident,
                        date: Date.new(2026, 4, 1))
      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:date]).to include('has already been taken')
    end

    # Regression test for BUG-3: uniqueness must be enforced at the database
    # level, not just Rails validations, to prevent race-condition double bookings.
    it 'enforces uniqueness at the database level' do
      community = create(:community)
      resident = create(:resident, community: community)
      create(:guest_room_reservation,
             community: community,
             resident: resident,
             date: Date.new(2026, 5, 1))

      duplicate = build(:guest_room_reservation,
                        community: community,
                        resident: resident,
                        date: Date.new(2026, 5, 1))
      expect do
        duplicate.save(validate: false)
      end.to raise_error(ActiveRecord::RecordNotUnique)
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

    it 'pushes the month of the day when it is created' do
      pushed = months_pushed do
        create(:guest_room_reservation, community: community, resident: resident, date: Date.new(2026, 4, 15))
      end

      expect(pushed).to eq([key(2026, 4)])
    end

    it 'pushes the old month as well as the new one when the day moves' do
      reservation = create(:guest_room_reservation, community: community, resident: resident,
                                                    date: Date.new(2026, 4, 15))

      pushed = months_pushed { reservation.update!(date: Date.new(2026, 6, 15)) }

      expect(pushed).to contain_exactly(key(2026, 4), key(2026, 6))
    end
  end
end
