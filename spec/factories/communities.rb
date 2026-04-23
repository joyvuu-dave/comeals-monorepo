# frozen_string_literal: true

# == Schema Information
#
# Table name: communities
#
#  id              :bigint           not null, primary key
#  cap             :decimal(12, 8)
#  name            :string           not null
#  singleton_guard :integer          default(0), not null
#  slug            :string           not null
#  timezone        :string           not null
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#
# Indexes
#
#  index_communities_on_name             (name) UNIQUE
#  index_communities_on_singleton_guard  (singleton_guard) UNIQUE
#  index_communities_on_slug             (slug) UNIQUE
#

FactoryBot.define do
  factory :community do
    name { 'Test Community' }
    # Explicit because the DB no longer defaults timezone — operators must
    # pick one at create time. Tests pin Pacific as a known fixture.
    timezone { 'America/Los_Angeles' }

    # Singleton: reuse the existing record so associated factories (unit, resident,
    # etc.) that call `association :community` don't violate the unique constraint.
    # Applies factory attributes to the existing record so explicit overrides like
    # `create(:community, cap: BigDecimal('4.50'))` are not silently swallowed.
    initialize_with do
      Community.first&.tap { |c| c.assign_attributes(attributes) } || new(**attributes)
    end

    to_create do |instance|
      instance.save! if instance.new_record? || instance.changed?
    end
  end
end
