# typed: true
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
class GuestRoomReservationSerializer
  include Alba::Resource

  CHIP_COLOR = '#bc7335'

  attributes :id,
             :type,
             :title,
             :start,
             :end,
             :url,
             :description,
             :color

  def id(reservation)
    reservation.cache_key_with_version
  end

  def type(reservation)
    reservation.class.to_s
  end

  def title(reservation)
    "Guest Room\n#{ResidentNameShortener.short(reservation.resident.name)} - Unit #{reservation.resident.unit.name}"
  end

  def description(reservation)
    "Guest Room\n#{ResidentNameShortener.short(reservation.resident.name)} - Unit #{reservation.resident.unit.name}"
  end

  def start(reservation)
    reservation.date + 1.minute
  end

  def end(reservation)
    reservation.date + 1.minute
  end

  def url(reservation)
    "guest-room-reservations/edit/#{reservation.id}"
  end

  def color(_reservation)
    CHIP_COLOR
  end
end
