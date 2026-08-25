# frozen_string_literal: true

# == Schema Information
#
# Table name: meals
#
#  id                :bigint           not null, primary key
#  cap               :decimal(12, 8)
#  closed            :boolean          default(FALSE), not null
#  closed_at         :datetime
#  date              :date             not null
#  description       :text             default(""), not null
#  max               :integer
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#  community_id      :bigint           not null
#  reconciliation_id :bigint
#  rotation_id       :bigint
#
# Indexes
#
#  index_meals_on_date               (date) UNIQUE
#  index_meals_on_reconciliation_id  (reconciliation_id)
#  index_meals_on_rotation_id        (rotation_id)
#
# Foreign Keys
#
#  fk_rails_...  (community_id => communities.id)
#  fk_rails_...  (reconciliation_id => reconciliations.id)
#  fk_rails_...  (rotation_id => rotations.id)
#

class MealSerializer
  include Alba::Resource

  CHIP_COLOR = '#444'

  attributes :id,
             :type,
             :title,
             :start,
             :end,
             :url,
             :description,
             :color

  def id(meal)
    meal.cache_key_with_version
  end

  def type(meal)
    meal.class.to_s
  end

  def title(meal)
    message = "Dinner\n#{meal.attendees_count}"

    today = Community.instance.today
    if today > meal.date
      message << ' attended'
      return message
    end

    message << ' attending' if today == meal.date

    message << ' signed up' if today < meal.date

    if meal.max.present?
      count = meal.max - meal.attendees_count
      message << "\n #{count} extra#{'s' unless count == 1}"
    end

    message
  end

  def start(meal)
    meal.date + 1.minute
  end

  def end(meal)
    meal.date + 1.minute
  end

  def url(meal)
    "/meals/#{meal.id}/edit"
  end

  def color(_meal)
    CHIP_COLOR
  end
end
