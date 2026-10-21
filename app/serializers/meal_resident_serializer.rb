# typed: true
# frozen_string_literal: true

# == Schema Information
#
# Table name: meal_residents
#
#  id           :bigint           not null, primary key
#  late         :boolean          default(FALSE), not null
#  multiplier   :integer          not null
#  vegetarian   :boolean          default(FALSE), not null
#  created_at   :datetime         not null
#  updated_at   :datetime         not null
#  community_id :bigint           not null
#  meal_id      :bigint           not null
#  resident_id  :bigint           not null
#
# Indexes
#
#  index_meal_residents_on_meal_id_and_resident_id  (meal_id,resident_id) UNIQUE
#  index_meal_residents_on_resident_id              (resident_id)
#
# Foreign Keys
#
#  fk_rails_...  (community_id => communities.id)
#  fk_rails_...  (meal_id => meals.id)
#  fk_rails_...  (resident_id => residents.id)
#
#
# Built with `params: { attendance_version: }`: the version of this
# person's attendance after the write (AttendanceVersion). The controller
# reads it inside the write's transaction, because a write action runs no
# query after its commit (spec/requests/no_query_after_commit_spec.rb).
class MealResidentSerializer
  include Alba::Resource

  attributes :id,
             :meal_id,
             :resident_id,
             :late,
             :vegetarian,
             :created_at,
             :attendance_version

  def attendance_version(_meal_resident)
    params.fetch(:attendance_version)
  end
end
