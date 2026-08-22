# frozen_string_literal: true

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
