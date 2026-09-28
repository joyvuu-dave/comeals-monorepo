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

# The date a meal gets when a spec does not give one. Each such meal is
# one day further back than the last, from yesterday to days_back days
# ago, and then the dates start again at yesterday. The sequence number
# is shared by the whole run and never reset. With no limit, the meals
# of the last spec files were dated further and further back as the
# suite grew. That changes prices: the resident factory counts a child's
# birthday back from today (8 years for half price), and a price is read
# on the meal's date, so on a meal more than three years back that child
# is under 5 and eats free (#117). spec/models/factory_price_bands_spec.rb
# checks the price bands at both ends of this window.
#
# Methods, not a constant: factory_bot_rails loads this file again on
# every code reload, and a constant would warn each time. `count` is the
# factory's sequence number, which starts at 1.
module DefaultMealDate
  def self.days_back = 730

  def self.for(count) = (((count - 1) % days_back) + 1).days.ago.to_date
end

FactoryBot.define do
  factory :meal do
    community
    sequence(:date) { |n| DefaultMealDate.for(n) }
  end
end
