# frozen_string_literal: true

# == Schema Information
#
# Table name: residents
#
#  id                     :bigint           not null, primary key
#  active                 :boolean          default(TRUE), not null
#  birthday               :date
#  can_cook               :boolean          default(TRUE), not null
#  can_reconcile          :boolean          default(FALSE), not null
#  email                  :string
#  keys_valid_since       :datetime         not null
#  name                   :string           not null
#  password_digest        :string           not null
#  phone                  :string
#  reset_password_sent_at :datetime
#  reset_password_token   :string
#  vegetarian             :boolean          default(FALSE), not null
#  created_at             :datetime         not null
#  updated_at             :datetime         not null
#  community_id           :bigint           not null
#  unit_id                :bigint           not null
#
# Indexes
#
#  index_residents_on_lower_email           (lower((email)::text)) UNIQUE
#  index_residents_on_lower_name            (lower((name)::text)) UNIQUE
#  index_residents_on_reset_password_token  (reset_password_token) UNIQUE
#  index_residents_on_unit_id               (unit_id)
#
# Foreign Keys
#
#  fk_rails_...  (community_id => communities.id)
#  fk_rails_...  (unit_id => units.id)
#

FactoryBot.define do
  factory :resident do
    community
    unit
    sequence(:name) { |n| "#{Faker::Name.first_name} #{Faker::Name.last_name} #{n}" }
    email { Faker::Internet.email }
    password { Faker::Internet.password }

    # A price band is not a column: it comes from the birthday. Specs
    # still say `multiplier: 1` for a child, and get an age-appropriate
    # birthday (8 for half price, 3 for free, under the default ages).
    # Adults get none — an adult with no birthday is the normal case.
    transient do
      multiplier { 2 }
    end

    birthday do
      case multiplier
      when 0 then 3.years.ago.to_date
      when 1 then 8.years.ago.to_date
      end
    end

    # Production creates a Key only at login. Tests treat a just-created
    # resident as already logged in for convenience — most request specs
    # reach for `resident.keys.first.token`.
    after(:create) do |resident, _evaluator|
      resident.keys.create! if resident.keys.empty?
    end
  end
end
