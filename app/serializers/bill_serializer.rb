# frozen_string_literal: true

# == Schema Information
#
# Table name: bills
#
#  id           :bigint           not null, primary key
#  amount       :decimal(12, 8)   default(0.0), not null
#  no_cost      :boolean          default(FALSE), not null
#  created_at   :datetime         not null
#  updated_at   :datetime         not null
#  community_id :bigint           not null
#  meal_id      :bigint           not null
#  resident_id  :bigint           not null
#
# Indexes
#
#  index_bills_on_meal_id_and_resident_id  (meal_id,resident_id) UNIQUE
#  index_bills_on_resident_id              (resident_id)
#
# Foreign Keys
#
#  fk_rails_...  (community_id => communities.id)
#  fk_rails_...  (meal_id => meals.id)
#  fk_rails_...  (resident_id => residents.id)
#
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
