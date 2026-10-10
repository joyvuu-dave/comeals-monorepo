# frozen_string_literal: true

# == Schema Information
#
# Table name: events
#
#  id           :bigint           not null, primary key
#  allday       :boolean          default(FALSE), not null
#  description  :string           default(""), not null
#  end_date     :datetime
#  start_date   :datetime         not null
#  title        :string           not null
#  created_at   :datetime         not null
#  updated_at   :datetime         not null
#  community_id :bigint           not null
#
# Indexes
#
#  index_events_on_start_date  (start_date)
#
# Foreign Keys
#
#  fk_rails_...  (community_id => communities.id)
#

FactoryBot.define do
  factory :event do
    title { 'Maintenance Committee Meeting' }
    # 2 to 3 PM two days ago, in the community's zone, so the event
    # starts and ends on one day there at any hour a spec runs (#154).
    transient do
      two_pm { 2.days.ago.in_time_zone(community.timezone).change(hour: 14) }
    end
    start_date { two_pm }
    end_date { two_pm + 1.hour }
    allday { false }
    community
  end
end
