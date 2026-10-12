# frozen_string_literal: true

require 'rails_helper'

# The list in the common house email (ADR 0011 rule 9): each unit with
# the people who lived there, people at $0.00 too, then the people who
# had moved out and still have a balance. All from the settlement's own
# lines and their saved units (rule 7).
RSpec.describe CollectionList do
  let(:community) { create(:community) }
  let(:latest) { Reconciliation.latest_cutoff(community.today) }
  let(:elm) { create(:unit, community: community, name: 'Elm') }
  let(:oak) { create(:unit, community: community, name: 'Oak') }
  let(:cook) { create(:resident, community: community, unit: elm, name: 'Casey Cook') }
  let(:eater) { create(:resident, community: community, unit: oak, name: 'Dana Diner') }
  let(:gone) { create(:resident, community: community, unit: oak, name: 'Gale Gone') }

  # The cook spends $30 on a dinner the eaters eat.
  def dinner(*eaters)
    meal = create(:meal, community: community, date: latest)
    create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('30'))
    eaters.each { |person| create(:meal_resident, meal: meal, resident: person, community: community) }
  end

  def units(list)
    list.units.map { |unit| [unit.name, unit.total, unit.people.map { |person| [person.name, person.amount] }] }
  end

  def moved_out(list)
    list.moved_out.map { |person| [person.name, person.amount] }
  end

  it 'lists each unit with its total and each person who lives there, people at $0.00 too' do
    dinner(eater)
    create(:resident, community: community, unit: oak, name: 'ari Idle')
    create(:resident, community: community, unit: oak, name: 'Moved Long Ago', active: false)
    create(:unit, community: community, name: 'Pine')
    reconciliation = settle!(cutoff: latest)

    list = described_class.new(reconciliation)

    expect(units(list)).to eq([['Elm', BigDecimal('30'), [['Casey Cook', BigDecimal('30')]]],
                               ['Oak', BigDecimal('-30'), [['ari Idle', 0], ['Dana Diner', BigDecimal('-30')]]]])
    expect(list.units.map(&:total)).to eq(reconciliation.unit_balances.values.reject(&:zero?))
    expect(moved_out(list)).to be_empty
  end

  it 'lists the people who had moved out by the day of the settlement on their own, outside every unit' do
    dinner(eater, gone)
    gone.update!(active: false)

    list = described_class.new(settle!(cutoff: latest))

    expect(units(list)).to eq([['Elm', BigDecimal('30'), [['Casey Cook', BigDecimal('30')]]],
                               ['Oak', BigDecimal('-15'), [['Dana Diner', BigDecimal('-15')]]]])
    expect(moved_out(list)).to eq([['Gale Gone', BigDecimal('-15')]])
  end

  it 'keeps each person in the unit saved on their line after they move, or move out' do
    dinner(eater)
    reconciliation = settle!(cutoff: latest)
    eater.update!(unit: elm)
    cook.update!(active: false)

    list = described_class.new(reconciliation)

    expect(units(list)).to eq([['Elm', BigDecimal('30'), [['Casey Cook', BigDecimal('30')]]],
                               ['Oak', BigDecimal('-30'), [['Dana Diner', BigDecimal('-30')]]]])
    expect(moved_out(list)).to be_empty
  end

  it 'counts everyone in their saved unit, with no moved-out list, for a settlement made before units were saved' do
    dinner(eater, gone)
    gone.update!(active: false)
    reconciliation = settle!(cutoff: latest)
    reconciliation.update_columns(units_recorded_on: reconciliation.date + 1)

    list = described_class.new(reconciliation)

    expect(units(list)).to eq(
      [['Elm', BigDecimal('30'), [['Casey Cook', BigDecimal('30')]]],
       ['Oak', BigDecimal('-30'), [['Dana Diner', BigDecimal('-15')], ['Gale Gone', BigDecimal('-15')]]]]
    )
    expect(moved_out(list)).to be_empty
  end
end
