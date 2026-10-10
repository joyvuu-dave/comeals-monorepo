# frozen_string_literal: true

# == Schema Information
#
# Table name: common_house_reservations
#
#  id           :bigint           not null, primary key
#  end_date     :datetime         not null
#  start_date   :datetime         not null
#  title        :string
#  created_at   :datetime         not null
#  updated_at   :datetime         not null
#  community_id :bigint           not null
#  resident_id  :bigint           not null
#
# Indexes
#
#  index_common_house_reservations_on_resident_id  (resident_id)
#  index_common_house_reservations_on_start_date   (start_date)
#
# Foreign Keys
#
#  fk_rails_...  (community_id => communities.id)
#  fk_rails_...  (resident_id => residents.id)
#

FactoryBot.define do
  factory :common_house_reservation do
    community
    resident
    # 2 to 3 PM three days ago, in the community's zone, so the booking
    # starts and ends on one day there at any hour a spec runs (#154).
    transient do
      two_pm { 3.days.ago.in_time_zone(community.timezone).change(hour: 14) }
    end
    start_date { two_pm }
    end_date { two_pm + 1.hour }
  end
end
