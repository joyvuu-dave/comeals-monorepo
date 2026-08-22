# frozen_string_literal: true

class BillSerializer
  include Alba::Resource
  include ActiveSupport::NumberHelper

  attributes :id,
             :type,
             :title,
             :start,
             :end,
             :url,
             :description

  def id(bill)
    bill.cache_key_with_version
  end

  def type(bill)
    bill.class.to_s
  end

  def title(bill)
    if bill.amount.positive? && bill.meal.date < Time.zone.today
      name = ResidentNameShortener.short(bill.resident.name)
      unit_name = bill.resident.unit.name
      "Cook\n#{name} - Unit #{unit_name}\n#{number_to_currency(bill.amount)}"
    else
      "Cook\n#{ResidentNameShortener.short(bill.resident.name)} - Unit #{bill.resident.unit.name}"
    end
  end

  def start(bill)
    bill.meal.date + 1.minute
  end

  def end(bill)
    bill.meal.date + 1.minute
  end

  def url(bill)
    "/meals/#{bill.meal_id}/edit"
  end

  def description(bill)
    if bill.amount.positive? && bill.meal.date < Time.zone.today
      name = ResidentNameShortener.short(bill.resident.name)
      unit_name = bill.resident.unit.name
      "Cook:  #{name} - Unit #{unit_name} - #{number_to_currency(bill.amount)}"
    else
      "Cook:  #{ResidentNameShortener.short(bill.resident.name)} - Unit #{bill.resident.unit.name}"
    end
  end
end
