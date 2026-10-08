# frozen_string_literal: true

require 'rails_helper'

RSpec.describe MealFormSerializer do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }

  describe '#residents' do
    it 'includes active residents' do
      active_resident = create(:resident, community: community, unit: unit, active: true, multiplier: 2)
      meal = create(:meal, community: community)

      resident_ids = described_class.new(meal).residents(meal).pluck(:id)

      expect(resident_ids).to include(active_resident.id)
    end

    it 'leaves out a retired resident who neither ate nor cooked at this meal' do
      inactive_nonattendee = create(:resident, community: community, unit: unit, active: false,
                                               multiplier: 2)
      meal = create(:meal, community: community)

      resident_ids = described_class.new(meal).residents(meal).pluck(:id)

      expect(resident_ids).not_to include(inactive_nonattendee.id)
    end

    it 'includes inactive residents who DID attend (the bug fix)' do
      resident = create(:resident, community: community, unit: unit, active: true, multiplier: 2)
      meal = create(:meal, community: community)

      # Resident attends meal while active
      create(:meal_resident, meal: meal, resident: resident, community: community)

      # Resident is later deactivated (moved/died)
      resident.update!(active: false)

      resident_ids = described_class.new(meal).residents(meal).pluck(:id)

      expect(resident_ids).to include(resident.id)
    end

    it 'does not duplicate residents who are active AND attending' do
      resident = create(:resident, community: community, unit: unit, active: true, multiplier: 2)
      meal = create(:meal, community: community)
      create(:meal_resident, meal: meal, resident: resident, community: community)

      resident_ids = described_class.new(meal).residents(meal).pluck(:id)

      # Should appear exactly once, not duplicated by the OR
      expect(resident_ids.count(resident.id)).to eq(1)
    end

    # The page can show and change a bill only when its cook is in this
    # list. Before #135 a bills save also removed the bill of any cook it
    # left out, so a cook missing from this list lost their bill on the
    # next save (#91). The request spec that reads the form and saves from
    # it, from start to end: spec/requests/api/v1/meal_form_retired_cook_spec.rb.
    # The meal is read again with none of its rows loaded: the serializer
    # must load the bills and sign-ups itself when no one has.
    it 'names every cook who has a bill on the meal, even a retired one who did not eat' do
      meal = create(:meal, community: community)
      cook = create(:resident, community: community, unit: unit)
      create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('40'))
      cook.update!(active: false)
      not_preloaded = Meal.find(meal.id)

      form = described_class.new(not_preloaded).to_h

      expect(form[:residents].pluck(:id)).to include(*form[:bills].pluck(:resident_id))
    end

    # A no-cost bill moves no money, but it is the record of who cooked.
    it 'names a retired cook whose bill is a no-cost bill' do
      meal = create(:meal, community: community)
      cook = create(:resident, community: community, unit: unit)
      create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('0'), no_cost: true)
      cook.update!(active: false)

      resident_ids = described_class.new(meal).residents(meal).pluck(:id)

      expect(resident_ids).to include(cook.id)
    end

    # The controller reads the meal with its bills and sign-ups first
    # (MealsController#set_meal), and this list later, in another
    # statement. The page is not read in one transaction, so a save can
    # commit between the two reads. The delete below stands for that
    # save. The list must come from the rows the meal already holds, or a
    # cook in `bills` can be missing from `residents`.
    it 'names every cook in bills when a bill is removed after the bills were read' do
      meal = create(:meal, community: community)
      cook = create(:resident, community: community, unit: unit)
      create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('40'))
      cook.update!(active: false)

      loaded = Meal.includes(:bills, :meal_residents, :guests).find(meal.id)
      Bill.where(meal_id: meal.id).delete_all

      form = described_class.new(loaded).to_h

      expect(form[:bills].pluck(:resident_id)).to eq([cook.id])
      expect(form[:residents].pluck(:id)).to include(cook.id)
    end

    # The same for sign-ups: the attending flags come from the sign-ups
    # the meal already holds, so the list must come from them too.
    # Otherwise a retired resident marked as attending in the rows read
    # first has no row in the list at all.
    it 'lists a retired eater when the sign-up is removed after the sign-ups were read' do
      meal = create(:meal, community: community)
      eater = create(:resident, community: community, unit: unit)
      create(:meal_resident, meal: meal, resident: eater, community: community)
      eater.update!(active: false)

      loaded = Meal.includes(:bills, :meal_residents, :guests).find(meal.id)
      MealResident.where(meal_id: meal.id).delete_all

      rows = described_class.new(loaded).to_h[:residents]

      expect(rows.select { |row| row[:attending] }.pluck(:id)).to eq([eater.id])
    end

    it 'leaves out a retired resident who ate or cooked only at another meal' do
      meal = create(:meal, community: community)
      other_meal = create(:meal, community: community)
      retired = create(:resident, community: community, unit: unit)
      create(:meal_resident, meal: other_meal, resident: retired, community: community)
      create(:bill, meal: other_meal, resident: retired, community: community)
      retired.update!(active: false)

      resident_ids = described_class.new(meal).residents(meal).pluck(:id)

      expect(resident_ids).not_to include(retired.id)
    end

    # With no ORDER BY, the rows come back in the order PostgreSQL
    # stored them, which no set of rows can pin: a row saved again can
    # land in a slot an earlier example's row left free, before the
    # others (spec/serializers/calendar_serializer_spec.rb, "the order of
    # every other list"). So this reads the statement.
    it 'asks for them by id' do
      meal = create(:meal, community: community)

      expect(described_class.new(meal).residents(meal).to_sql).to end_with(' ORDER BY "residents"."id" ASC')
    end
  end

  describe 'the links to the meals before and after' do
    it 'point at the nearest meal each way, and at the meal itself at either end' do
      first = create(:meal, community: community, date: Date.new(2026, 4, 5))
      middle = create(:meal, community: community, date: Date.new(2026, 4, 12))
      last = create(:meal, community: community, date: Date.new(2026, 4, 19))

      expect(described_class.new(middle).to_h).to include(prev_id: first.id, next_id: last.id, reconciled: false)
      expect(described_class.new(first).to_h).to include(prev_id: first.id, next_id: middle.id)
      expect(described_class.new(last).to_h).to include(prev_id: middle.id, next_id: last.id)
    end

    # Made out of date order. Of the meals after April 10, the one made
    # first is April 30; of the meals before May 10, the one made last is
    # April 20. Going by date gives April 20 and April 30.
    it 'goes by date, not by the order the meals were made' do
      april30 = create(:meal, community: community, date: Date.new(2026, 4, 30))
      april10 = create(:meal, community: community, date: Date.new(2026, 4, 10))
      may10 = create(:meal, community: community, date: Date.new(2026, 5, 10))
      april20 = create(:meal, community: community, date: Date.new(2026, 4, 20))

      expect(described_class.new(april10).to_h).to include(next_id: april20.id)
      expect(described_class.new(may10).to_h).to include(prev_id: april30.id)
    end

    it 'says a settled meal is reconciled with a plain true' do
      meal = create(:meal, community: community)
      meal.update!(reconciliation: create(:reconciliation, community: community))

      expect(described_class.new(meal).to_h[:reconciled]).to be(true)
    end
  end

  describe 'a resident row' do
    let(:home) { create(:unit, community: community, name: 'B7') }

    def row(meal, resident)
      described_class.new(meal).to_h.fetch(:residents).find { |r| r[:id] == resident.id }
    end

    it 'carries the attendance flags from the sign-up when there is one' do
      meal = create(:meal, community: community)
      resident = create(:resident, community: community, unit: home, name: 'Ann Lee', multiplier: 2,
                                   vegetarian: false, can_cook: true)
      attendance = create(:meal_resident, meal: meal, resident: resident, community: community, late: true,
                                          vegetarian: true)

      expect(row(meal, resident)).to eq(
        id: resident.id, meal_id: meal.id, name: 'B7 - Ann Lee', short_name: 'Ann Lee', attending: true,
        attending_at: attendance.created_at, late: true, vegetarian: true, can_cook: true, active: true
      )
    end

    it 'falls back to the resident\'s own diet, and no lateness, without a sign-up' do
      meal = create(:meal, community: community)
      resident = create(:resident, community: community, unit: home, name: 'Bea Ortiz', multiplier: 2,
                                   vegetarian: true)

      expect(row(meal, resident)).to include(attending: false, attending_at: nil, late: false, vegetarian: true)
    end
  end
end
