# frozen_string_literal: true

# == Schema Information
#
# Table name: rotations
#
#  id                       :bigint           not null, primary key
#  color                    :string           not null
#  new_rotation_notified_at :datetime
#  place_value              :integer
#  residents_notified       :boolean          default(FALSE), not null
#  created_at               :datetime         not null
#  updated_at               :datetime         not null
#  community_id             :bigint           not null
#
# Foreign Keys
#
#  fk_rails_...  (community_id => communities.id)
#
class RotationSerializer
  include Alba::Resource

  attributes :id,
             :type,
             :start,
             :end,
             :color,
             :title,
             :url

  def id(rotation)
    rotation.cache_key_with_version
  end

  def type(rotation)
    rotation.class.to_s
  end

  def start(rotation)
    first_date = if rotation.meals.loaded?
                   rotation.meals.min_by(&:date)&.date
                 else
                   rotation.meals.minimum(:date)
                 end
    first_date&.+(1.minute)
  end

  def end(rotation)
    last_date = if rotation.meals.loaded?
                  rotation.meals.max_by(&:date)&.date
                else
                  rotation.meals.maximum(:date)
                end
    last_date && (last_date + 1.day - 1.minute) # ReactBigCalendar date ranges are exclusive
  end

  def title(rotation)
    "Rotation #{rotation.place_value}"
  end

  def url(rotation)
    "rotations/show/#{rotation.id}"
  end
end
