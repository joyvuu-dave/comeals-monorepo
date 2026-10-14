# frozen_string_literal: true

require 'rails_helper'

# Reading the admin correction form (ADR 0011 rule 6) into
# MealCorrecting's edits. The form sends every row, changed or not; only
# the rows that change something become edits, in one order, and what
# cannot be read is refused with a sentence before anything changes.
# The request spec (spec/requests/admin/meal_correction_form_spec.rb)
# runs the whole page.
RSpec.describe MealCorrectionForm do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:latest) { Reconciliation.latest_cutoff(community.today) }
  # Two cooks whose names sort the other way from their ids.
  let!(:zed) { create(:resident, community: community, unit: unit, name: 'Zed Cook') }
  let!(:amy) { create(:resident, community: community, unit: unit, name: 'Amy Cook') }
  let(:eater) { create(:resident, community: community, unit: unit, name: 'Eater One') }
  let(:other) { create(:resident, community: community, unit: unit, name: 'Other One') }
  let!(:meal) do
    create(:meal, community: community, date: latest - 5).tap do |meal|
      create(:bill, meal: meal, resident: zed, community: community, amount: BigDecimal('30'))
      create(:bill, meal: meal, resident: amy, community: community, amount: BigDecimal('0'), no_cost: true)
      create(:meal_resident, meal: meal, resident: eater, community: community)
      settle!(cutoff: latest - 5)
    end.reload
  end

  # The edits the form makes, by running them in a preview.
  def edits(values)
    form = described_class.new(meal, values.deep_stringify_keys)
    MealCorrecting.preview(meal) { |edits| form.apply(edits) }.edits
  end

  def refusal(values)
    described_class.new(meal, values.deep_stringify_keys)
    nil
  rescue described_class::Invalid => e
    e.message
  end

  def cooks(zed: { amount: '30.00', no_cost: '0' }, amy: { amount: '', no_cost: '1' })
    { cooks: { self.zed.id => zed, self.amy.id => amy } }
  end

  it 'makes no edit for rows sent as they are, or rows not sent' do
    expect { edits(cooks.merge(eaters: { eater.id => 'keep' }, new_eater_ids: [''])) }
      .to raise_error(MealCorrecting::NothingChanged)
    expect { edits({}) }.to raise_error(MealCorrecting::NothingChanged)
  end

  it 'reads a part that is not a set of rows as empty' do
    expect { edits(cooks: 'all of them', eaters: %w[remove], guests: 7) }.to raise_error(MealCorrecting::NothingChanged)
  end

  it 'makes the edits in the order of the names, whatever the order of the ids' do
    changed = edits(cooks(zed: { amount: '25' }, amy: { amount: '5', no_cost: '0' }))

    expect(changed.pluck('resident_id')).to eq([amy.id, zed.id])
  end

  it 'takes a cost with spaces around it, and a cost marked No cost with no amount' do
    expect(edits(cooks(zed: { amount: ' 25.5 ' }, amy: { amount: '', no_cost: '1' })).sole)
      .to include('resident_id' => zed.id, 'to' => { 'amount' => '25.5', 'no_cost' => false })
    expect(edits(cooks(zed: { amount: '', no_cost: '1' })).sole)
      .to include('resident_id' => zed.id, 'to' => { 'amount' => '0.0', 'no_cost' => true })
  end

  it 'refuses a cost marked No cost that has an amount, naming the cook' do
    expect(refusal(cooks(zed: { amount: '4', no_cost: '1' })))
      .to eq("Zed Cook: #{Bill::NO_COST_MEANS_NO_AMOUNT}")
  end

  it 'refuses a cost over 9999.99' do
    expect(refusal(cooks(zed: { amount: '10000' })))
      .to eq('Zed Cook: "10000" is not a cost. A cost is whole cents, 0 to 9999.99, like 25.50.')
  end

  it 'refuses to add a cook who is a cook already' do
    expect(refusal(new_cook: { resident_id: amy.id.to_s, amount: '3' }))
      .to eq('Amy Cook is already a cook on this dinner. Change their cost in their own row.')
  end

  it 'adds a cook with their cost, and needs a cost or No cost' do
    expect(edits(new_cook: { resident_id: other.id.to_s, amount: '3' }).sole)
      .to eq('what' => 'cost', 'resident_id' => other.id, 'from' => nil,
             'to' => { 'amount' => '3.0', 'no_cost' => false })
    expect(refusal(new_cook: { resident_id: other.id.to_s, amount: '' }))
      .to eq('Other One: enter a cost, or tick No cost.')
  end

  it 'refuses to sign up someone who already ate, and signs up the rest in name order' do
    expect(refusal(new_eater_ids: [other.id.to_s, eater.id.to_s])).to eq('Eater One already ate this dinner.')

    amos = create(:resident, community: community, unit: unit, name: 'Amos Late')
    expect(edits(new_eater_ids: [other.id.to_s, amos.id.to_s, other.id.to_s]).pluck('resident_id'))
      .to eq([amos.id, other.id])
  end

  it 'refuses a resident that does not exist, in each menu' do
    missing = 'The form named a resident who does not exist. ' \
              'This dinner changed after the form was opened. Open the form again.'

    expect(refusal(new_cook: { resident_id: '0', amount: '3' })).to eq(missing)
    expect(refusal(new_cook: { resident_id: 'x', amount: '3' })).to eq(missing)
    expect(refusal(new_eater_ids: ['0'])).to eq(missing)
    expect(refusal(new_eater_ids: ['x'])).to eq(missing)
    expect(refusal(new_guest: { host_id: '0', multiplier: '2' })).to eq(missing)
  end

  it 'adds a guest at an adult or a child price, and nothing else' do
    expect(edits(new_guest: { host_id: eater.id.to_s, multiplier: '1' }).sole)
      .to eq('what' => 'guest', 'resident_id' => eater.id, 'from' => nil, 'to' => Multiplier::HALF)
    # One line each, not a loop: prosopite reads one line that queries
    # again and again as an N+1.
    expect(refusal(new_guest: { host_id: eater.id.to_s, multiplier: '0' })).to eq('A guest is an adult or a child.')
    expect(refusal(new_guest: { host_id: eater.id.to_s, multiplier: '3' })).to eq('A guest is an adult or a child.')
    expect(refusal(new_guest: { host_id: eater.id.to_s, multiplier: 'x' })).to eq('A guest is an adult or a child.')
  end

  it 'refuses a choice for an eater it does not know' do
    expect(refusal(eaters: { eater.id => 'double' }))
      .to eq('The form sent "double" for an eater. This dinner changed after the form was opened. Open the form again.')
  end

  it 'refuses a cook, an eater or a guest the dinner does not have' do
    changed = 'This dinner changed after the form was opened. Open the form again.'

    expect(refusal(cooks: { other.id => { amount: '3' } })).to eq(changed)
    expect(refusal(eaters: { other.id => 'remove' })).to eq(changed)
    expect(refusal(guests: { '0' => { remove: '1' } })).to eq(changed)
  end

  it 'reads the reason without spaces around it' do
    expect(described_class.new(meal, { 'reason' => "  Typed $30\n" }).reason).to eq('Typed $30')
    expect(described_class.new(meal, {}).reason).to eq('')
  end
end
