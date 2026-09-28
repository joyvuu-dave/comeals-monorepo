# typed: true
# frozen_string_literal: true

# A birthday chip on the calendar. Build it with
# `params: { days: first_day..last_day }`, the days on screen.
#
# The chip goes on the birthday in the year those days give its month,
# not in this year. The December grid ends in the next January, and a
# person can page to any month of another year (#101). The days on
# screen are at most 42, so each month number is in them once, and the
# month names one year. The caller sends only residents whose birthday
# month is on screen, and who were born by the last day on screen, so
# no chip falls before a birth.
class ResidentBirthdaySerializer
  include Alba::Resource

  CHIP_COLOR = '#7335bc'

  attributes :id,
             :type,
             :title,
             :description,
             :start,
             :end,
             :color

  def id(resident)
    resident.cache_key_with_version
  end

  def type(_resident)
    'Birthday'
  end

  def title(resident)
    if age_turned(resident) < 22
      "#{ResidentNameShortener.short(resident.name)}'s #{age_turned(resident).ordinalize} B-day!"
    else
      "#{ResidentNameShortener.short(resident.name)}'s B-day!"
    end
  end

  def description(resident)
    if age_turned(resident) < 22
      "#{ResidentNameShortener.short(resident.name)}'s #{age_turned(resident).ordinalize} Birthday!"
    else
      "#{ResidentNameShortener.short(resident.name)}'s Birthday!"
    end
  end

  def start(resident)
    chip_date(resident)
  end

  def end(resident)
    chip_date(resident)
  end

  def color(_resident)
    CHIP_COLOR
  end

  private

  def chip_date(resident)
    birthday = resident.birthday
    year = T.must(params.fetch(:days).find { |day| day.month == birthday.month }).year
    Date.new(year, birthday.month, birthday.day)
  rescue Date::Error
    # Feb 29 birthday in a non-leap year — display on Feb 28
    Date.new(year, 2, 28)
  end

  # The age the person turns on the chip's day, not their age today. The
  # label must not change on the birthday itself. It is the chip's year
  # minus the birth year, not Resident#age_on(chip date): a February 29
  # birthday is drawn on February 28 in other years, and age_on adds the
  # year on March 1.
  def age_turned(resident)
    chip_date(resident).year - resident.birthday.year
  end
end
