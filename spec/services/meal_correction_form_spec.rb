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

  # Amy sorts first. A cook row left out, or sent as text and not as a set
  # of boxes, changes nothing, and the rows after it are still read.
  it 'reads the next cook after a row that was left out or sent as text' do
    expect(edits(cooks: { zed.id => { amount: '25' } }).pluck('resident_id')).to eq([zed.id])
    expect(edits(cooks: { amy.id => 'remove', zed.id => { amount: '25' } }).pluck('resident_id')).to eq([zed.id])
  end

  # A ticked Remove box wins over the cost boxes in the same row, and the
  # rows after it are still read.
  it 'takes off a cook whose Remove box is ticked, whatever the cost boxes say' do
    expect(edits(cooks(amy: { amount: '7', no_cost: '0', remove: '1' }, zed: { amount: '25' })))
      .to match([include('resident_id' => amy.id, 'to' => nil), include('resident_id' => zed.id)])
    expect(edits(cooks(zed: { amount: '', no_cost: '0', remove: '1' })).sole)
      .to include('resident_id' => zed.id, 'to' => nil)
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

  # The example above has the ids in the other order from the names. This
  # one has them in the same order, so a sort by anything but the name
  # (the order Ruby made the records in, say) cannot pass both.
  it 'signs up in name order when the ids are in name order too' do
    ann = create(:resident, community: community, unit: unit, name: 'Ann First')
    bob = create(:resident, community: community, unit: unit, name: 'Bob Second')

    expect(edits(new_eater_ids: [bob.id.to_s, ann.id.to_s]).pluck('resident_id')).to eq([ann.id, bob.id])
  end

  it 'refuses a resident that does not exist, in each menu' do
    missing = 'The form named a resident who does not exist. ' \
              'This dinner changed after the form was opened. Open the form again.'

    expect(refusal(new_cook: { resident_id: '0', amount: '3' })).to eq(missing)
    expect(refusal(new_cook: { resident_id: 'x', amount: '3' })).to eq(missing)
    expect(refusal(new_eater_ids: ['0'])).to eq(missing)
    expect(refusal(new_eater_ids: ['x'])).to eq(missing)
    # Text that starts with a resident's id is still not their id.
    expect(refusal(new_eater_ids: ["#{other.id}x"])).to eq(missing)
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

  # A caller other than the page (the console, a spec) can send a number
  # where the page sends text, or leave a box out.
  it 'reads a cook row with no amount box as no amount' do
    expect(edits(cooks(zed: { no_cost: '1' })).sole)
      .to include('resident_id' => zed.id, 'to' => { 'amount' => '0.0', 'no_cost' => true })
  end

  it 'reads a tick sent as the number 1' do
    expect(edits(cooks(zed: { amount: '', no_cost: 1 })).sole)
      .to include('resident_id' => zed.id, 'to' => { 'amount' => '0.0', 'no_cost' => true })
  end

  it 'reads ids sent as numbers, and leaves out an empty one' do
    expect(edits(new_eater_ids: [nil, other.id]).sole).to include('what' => 'eater', 'resident_id' => other.id)
  end

  # Another admin's correction takes Zed off as a cook after this form
  # read the dinner and before its edits run. This form sent Zed's row as
  # it was, so it makes no edit for Zed, and Zed stays off.
  it 'makes no edit for a row sent as it is, even when the row is gone by the time the edits run' do
    form = described_class.new(meal, cooks.merge(new_eater_ids: [other.id.to_s]).deep_stringify_keys)
    MealCorrecting.save!(meal, by: create(:admin_user, community: community, superuser: true),
                               reason: 'Zed did not cook') { |edits| edits.remove_cook(zed) }

    result = MealCorrecting.preview(meal.reload) { |edits| form.apply(edits) }

    expect(result.edits.pluck('what', 'resident_id')).to eq([['eater', other.id]])
  end

  # Before ADR 0011 rule 3, a dinner whose cook had not entered a cost was
  # settled anyway, at $0 and not No cost. Ticking No cost keeps the
  # amount at $0 and is still a change.
  it 'marks a cost that was never entered as No cost' do
    blank = create(:resident, community: community, unit: unit, name: 'Blank Cook')
    dinner = create(:meal, community: community, date: latest - 2).tap do |meal|
      create(:bill, meal: meal, resident: blank, community: community, amount: BigDecimal('0'))
      create(:meal_resident, meal: meal, resident: eater, community: community)
    end
    settle_as_before_rule_3!(cutoff: latest - 2)
    form = described_class.new(dinner.reload, { 'cooks' => { blank.id.to_s => { 'amount' => '', 'no_cost' => '1' } } })

    expect(MealCorrecting.preview(dinner) { |edits| form.apply(edits) }.edits).to eq(
      [{ 'what' => 'cost', 'resident_id' => blank.id, 'from' => { 'amount' => '0.0', 'no_cost' => false },
         'to' => { 'amount' => '0.0', 'no_cost' => true } }]
    )
  end

  # The edits are made in the order the rows are read, and a preview and
  # the save after it must make them in the same order (the fingerprint).
  # So the order must not depend on the order the database returns rows
  # in, which it does not promise without ORDER BY.
  context 'with eaters and guests whose names sort the other way from their ids' do
    let(:yan) { create(:resident, community: community, unit: unit, name: 'Yan Eater') }
    let(:abe) { create(:resident, community: community, unit: unit, name: 'Abe Eater') }
    let!(:meal) do
      create(:meal, community: community, date: latest - 5).tap do |meal|
        create(:bill, meal: meal, resident: zed, community: community, amount: BigDecimal('30'))
        [yan, abe].each { |person| create(:meal_resident, meal: meal, resident: person, community: community) }
        # Two guests of Yan, the adult first, then a guest of Abe.
        create(:guest, meal: meal, resident: yan, multiplier: Multiplier::FULL)
        create(:guest, meal: meal, resident: yan, multiplier: Multiplier::HALF)
        create(:guest, meal: meal, resident: abe, multiplier: Multiplier::FULL)
        settle!(cutoff: latest - 5)
      end.reload
    end

    # The form as it reads the rows when the database returns them newest
    # first.
    def read_newest_first(values)
      newest_first = ->(original, *args) { original.call(*args).order(id: :desc) }
      [Bill, MealResident, Guest].each { |model| allow(model).to receive(:where).and_wrap_original(&newest_first) }
      form = described_class.new(meal, values.deep_stringify_keys)
      [Bill, MealResident, Guest].each { |model| allow(model).to receive(:where).and_call_original }
      MealCorrecting.preview(meal) { |edits| form.apply(edits) }.edits
    end

    it 'takes the eaters off in the order of their names' do
      expect(edits(eaters: { yan.id => 'remove', abe.id => 'remove' }).pluck('resident_id')).to eq([abe.id, yan.id])
    end

    it 'reads an eater\'s choice sent as a symbol' do
      expect(edits(eaters: { yan.id => :remove }).sole).to include('what' => 'eater', 'resident_id' => yan.id)
    end

    it 'takes the guests off in the order of their hosts\' names, and a host\'s guests in the order they were added' do
      guests = meal.guests.order(:id).to_h { |guest| [guest.id, { remove: '1' }] }

      expect(edits(guests: guests).pluck('resident_id', 'from'))
        .to eq([[abe.id, Multiplier::FULL], [yan.id, Multiplier::FULL], [yan.id, Multiplier::HALF]])
      expect(read_newest_first(guests: guests).pluck('resident_id', 'from'))
        .to eq([[abe.id, Multiplier::FULL], [yan.id, Multiplier::FULL], [yan.id, Multiplier::HALF]])
    end

    # Only a ticked Remove box takes a guest off. A guest the form left
    # out, sent with no Remove box, or sent as something that is not a set
    # of boxes, stays.
    it 'takes off only the guests whose Remove box is ticked' do
      abes, yans_adult, yans_child = meal.guests.sort_by { |guest| [guest.resident.name, guest.id] }

      expect(edits(guests: { abes.id => { remove: '1' }, yans_adult.id => {} }).sole)
        .to include('what' => 'guest', 'resident_id' => abe.id, 'from' => Multiplier::FULL)
      expect(edits(guests: { abes.id => [], yans_adult.id => 1, yans_child.id => { remove: '1' } }).sole)
        .to include('what' => 'guest', 'resident_id' => yan.id, 'from' => Multiplier::HALF)
    end

    it 'refuses to sign up one of several people who already ate' do
      expect(refusal(new_eater_ids: [abe.id.to_s])).to eq('Abe Eater already ate this dinner.')
    end
  end
end
