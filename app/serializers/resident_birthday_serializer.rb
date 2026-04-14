# frozen_string_literal: true

class ResidentBirthdaySerializer < ActiveModel::Serializer
  include ApplicationHelper

  attributes :id,
             :type,
             :title,
             :description,
             :start,
             :end,
             :color

  def id
    object.cache_key_with_version
  end

  def type
    'Birthday'
  end

  def title
    if object.age < 22
      "#{resident_name_helper(object.name)}'s #{object.age.ordinalize} B-day!"
    else
      "#{resident_name_helper(object.name)}'s B-day!"
    end
  end

  def description
    if object.age < 22
      "#{resident_name_helper(object.name)}'s #{object.age.ordinalize} Birthday!"
    else
      "#{resident_name_helper(object.name)}'s Birthday!"
    end
  end

  def start
    year = Time.zone.today.year
    Date.new(year, object.birthday.month, object.birthday.day)
  rescue ArgumentError
    # Feb 29 birthday in a non-leap year — display on Feb 28
    Date.new(year, 2, 28)
  end

  def end
    year = Time.zone.today.year
    Date.new(year, object.birthday.month, object.birthday.day)
  rescue ArgumentError
    Date.new(year, 2, 28)
  end

  def color
    '#7335bc'
  end
end
