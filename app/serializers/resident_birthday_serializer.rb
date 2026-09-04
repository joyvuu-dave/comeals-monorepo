# typed: true
# frozen_string_literal: true

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
    if resident.age < 22
      "#{ResidentNameShortener.short(resident.name)}'s #{resident.age.ordinalize} B-day!"
    else
      "#{ResidentNameShortener.short(resident.name)}'s B-day!"
    end
  end

  def description(resident)
    if resident.age < 22
      "#{ResidentNameShortener.short(resident.name)}'s #{resident.age.ordinalize} Birthday!"
    else
      "#{ResidentNameShortener.short(resident.name)}'s Birthday!"
    end
  end

  def start(resident)
    birthday_this_year(resident)
  end

  def end(resident)
    birthday_this_year(resident)
  end

  def color(_resident)
    CHIP_COLOR
  end

  private

  def birthday_this_year(resident)
    year = Community.instance.today.year
    Date.new(year, resident.birthday.month, resident.birthday.day)
  rescue ArgumentError
    # Feb 29 birthday in a non-leap year — display on Feb 28
    Date.new(year, 2, 28)
  end
end
