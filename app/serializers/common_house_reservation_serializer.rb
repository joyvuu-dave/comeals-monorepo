# typed: true
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
class CommonHouseReservationSerializer
  include Alba::Resource

  CHIP_COLOR = '#bc357e'

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
    time_range = "#{reservation.start_date.strftime('%l:%M%P')} - " \
                 "#{reservation.end_date.strftime('%l:%M%P')}"
    title_line = "#{reservation.title}\n" if reservation.title.present?
    name = ResidentNameShortener.short(reservation.resident.name)
    unit_name = reservation.resident.unit.name
    "#{time_range}\nCommon House\n#{title_line}#{name} - Unit #{unit_name}"
  end

  def description(reservation)
    "Common House\n#{ResidentNameShortener.short(reservation.resident.name)} - Unit #{reservation.resident.unit.name}"
  end

  def start(reservation)
    reservation.start_date + 1.minute
  end

  def end(reservation)
    reservation.end_date + 1.minute
  end

  def url(reservation)
    "common-house-reservations/edit/#{reservation.id}"
  end

  def color(_reservation)
    CHIP_COLOR
  end
end
