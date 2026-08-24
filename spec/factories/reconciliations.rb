# frozen_string_literal: true

# == Schema Information
#
# Table name: reconciliations
#
#  id           :bigint           not null, primary key
#  date         :date             not null
#  end_date     :date             not null
#  created_at   :datetime         not null
#  updated_at   :datetime         not null
#  community_id :bigint           not null
#
# Foreign Keys
#
#  fk_rails_...  (community_id => communities.id)
#
FactoryBot.define do
  factory :reconciliation do
    community
    date { Time.zone.today }

    # A reconciliation must settle at least one meal, so the factory builds one
    # for itself: a unit, a cook, a meal, and a bill on that meal. Most specs
    # use this factory only to get a row they can point a meal at, and do not
    # care what it settled.
    #
    # The cutoff stays Date.yesterday, so the sweep on create still claims
    # every eligible meal a spec has already created. Many specs depend on
    # that: they build a meal, then create a reconciliation to settle it.
    #
    # The factory's own meal is dated in 2000, decades before the meal
    # factory's dates (which count back from today), so it sorts clear of any
    # meal a spec created and cannot collide with one. Each call gets its own
    # day, because meals.date carries a unique index.
    transient do
      sequence(:settled_meal_date) { |n| Date.new(2000, 1, 1) + n.days }
    end

    end_date { Date.yesterday }

    # Creating a reconciliation means settling a period, so the factory goes
    # through Settlement like every other path does.
    to_create { |reconciliation| Settlement.new(reconciliation).settle! }

    before(:create) do |reconciliation, evaluator|
      unit = create(:unit, community: reconciliation.community)
      cook = create(:resident, community: reconciliation.community, unit: unit)
      meal = create(:meal, community: reconciliation.community, date: evaluator.settled_meal_date)
      create(:bill, meal: meal, resident: cook, community: reconciliation.community,
                    amount: BigDecimal('10'))
    end
  end
end
