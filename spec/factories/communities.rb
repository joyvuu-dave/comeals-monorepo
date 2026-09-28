# frozen_string_literal: true

# == Schema Information
#
# Table name: communities
#
#  id                 :bigint           not null, primary key
#  cap                :decimal(12, 8)
#  dinner_start_times :jsonb            not null
#  free_below_age     :integer          default(5), not null
#  full_price_age     :integer          default(12), not null
#  meals_per_rotation :integer          default(12), not null
#  name               :string           not null
#  schedule           :jsonb            not null
#  singleton_guard    :integer          default(0), not null
#  timezone           :string           not null
#  created_at         :datetime         not null
#  updated_at         :datetime         not null
#
# Indexes
#
#  index_communities_on_name             (name) UNIQUE
#  index_communities_on_singleton_guard  (singleton_guard) UNIQUE
#

FactoryBot.define do
  factory :community do
    name { 'Test Community' }
    # Explicit because the DB no longer defaults timezone — operators must
    # pick one at create time. Tests pin Pacific as a known fixture.
    timezone { 'America/Los_Angeles' }

    # Singleton: reuse the existing record so associated factories (unit, resident,
    # etc.) that call `association :community` don't violate the unique constraint.
    # Applies only what the caller gave (`__override_names__`, FactoryBot's list
    # of the attributes passed in) to the existing record, so an explicit
    # override like `create(:community, cap: BigDecimal('4.50'))` is not
    # silently swallowed, and the defaults above never overwrite a row a spec
    # has changed: every other factory asks for a community with no overrides.
    # The names are read before `attributes`: FactoryBot caches each default
    # in the same hash it keeps the overrides in, so once `attributes` has
    # run, every name looks passed in.
    initialize_with do
      given = __override_names__
      Community.first&.tap { |community| community.assign_attributes(attributes.slice(*given)) } ||
        new(**attributes)
    end

    to_create do |instance|
      instance.save! if instance.new_record? || instance.changed?
    end
  end
end
