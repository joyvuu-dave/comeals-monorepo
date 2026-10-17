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

  # The form as a page opened now sends it: with the code of the rows it
  # shows, unless the values name their own.
  def opened(values, dinner: meal)
    described_class.new(dinner, { 'seen' => described_class::Rows.of(dinner).seen }.merge(values.deep_stringify_keys))
  end

  # The edits the form makes, by running them in a preview.
  def edits(values)
    form = opened(values)
    MealCorrecting.preview(meal) { |edits| form.apply(edits) }.edits
  end

  def refusal(values)
    opened(values)
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

  # Six people made in an order that is neither their name order nor its
  # reverse, so a sort by anything but the name (the id, or where Ruby
  # put each record in memory) is very unlikely to pass. Two people were
  # not enough: in a mutant run, a sort by memory address passed both
  # examples with two.
  it 'signs up six people in name order, whatever order they were made in' do
    people = %w[Cara Abby Ezra Bart Fern Dale].map do |name|
      create(:resident, community: community, unit: unit, name: "#{name} Six")
    end

    expect(edits(new_eater_ids: people.map { |person| person.id.to_s }).pluck('resident_id'))
      .to eq(people.sort_by(&:name).map(&:id))
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
    expect(opened({ 'reason' => "  Typed $30\n" }).reason).to eq('Typed $30')
    expect(opened({}).reason).to eq('')
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

  describe 'the code of the rows the page showed' do
    let(:admin) { create(:admin_user, community: community, superuser: true) }

    def correct_zed_to(amount)
      MealCorrecting.save!(meal, by: admin, reason: 'The receipt') do |edits|
        edits.cost(zed, amount: BigDecimal(amount), no_cost: false)
      end
    end

    it 'refuses a form with no code, or a blank one' do
      expect(refusal(cooks.merge(seen: nil))).to eq(described_class::STALE)
      expect(refusal(cooks.merge(seen: ''))).to eq(described_class::STALE)
      expect(refusal(cooks.merge(seen: ' '))).to eq(described_class::STALE)
    end

    # The code the form had when it was opened, before another admin's
    # correction changed Zed's cost.
    it 'refuses a form opened before the dinner changed' do
      seen = described_class::Rows.of(meal).seen
      correct_zed_to('25')

      expect(refusal(cooks.merge(seen: seen, new_eater_ids: [other.id.to_s]))).to eq(described_class::STALE)
    end

    # Another admin's correction is saved after this form read the dinner
    # and before its edits run under the meal's lock.
    it 'refuses again under the lock when the dinner changed after the form was read' do
      form = opened(cooks.merge(new_eater_ids: [other.id.to_s]))
      correct_zed_to('25')

      expect { MealCorrecting.preview(meal.reload) { |edits| form.apply(edits) } }
        .to raise_error(described_class::Invalid, described_class::STALE)
      expect(meal.bills.find_by(resident: zed).amount).to eq(25)
    end

    # Each thing the page shows of a row changes the code: a cook's cost
    # and No cost, an eater's price, which eaters and cooks there are, and
    # each guest. It reads the rows again after each write, which is the
    # repeat prosopite would refuse.
    it 'changes with each thing the page shows of the rows', prosopite: false do
      codes = [described_class::Rows.of(meal).seen]
      writes = [
        -> { Bill.where(resident: zed).update_all(amount: BigDecimal('25')) },
        -> { Bill.where(resident: amy).update_all(no_cost: false) },
        -> { MealResident.where(resident: eater).update_all(multiplier: Multiplier::HALF) },
        -> { MealResident.where(resident: eater).update_all(resident_id: other.id) },
        -> { Bill.where(resident: amy).delete_all },
        lambda do
          Guest.insert_all!([{ meal_id: meal.id, resident_id: eater.id, multiplier: Multiplier::FULL }])
        end
      ]
      # Each write is a repair from psql, rolled back after its code is read.
      writes.each do |write|
        with_repair_bypass do
          write.call
          codes << described_class::Rows.of(meal).seen
          raise ActiveRecord::Rollback
        end
      end

      expect(codes.uniq.size).to eq(writes.size + 1)
    end

    # The same for a guest the dinner already has: its price, its host,
    # and a guest put in its place with the same host and price. And a
    # cook put in another cook's place, in the same row, at the same cost.
    it 'changes with each guest, and with who each cook is', prosopite: false do
      other # made now: made inside a write below, it would be rolled back with it
      guest = { meal_id: meal.id, resident_id: eater.id, multiplier: Multiplier::FULL }
      with_repair_bypass { Guest.insert_all!([guest]) }
      codes = [described_class::Rows.of(meal).seen]
      writes = [
        -> { Guest.where(meal: meal).update_all(multiplier: Multiplier::HALF) },
        -> { Guest.where(meal: meal).update_all(resident_id: other.id) },
        lambda do
          Guest.where(meal: meal).delete_all
          Guest.insert_all!([guest])
        end,
        lambda do
          Bill.where(resident: zed).delete_all
          Bill.insert_all!([{ meal_id: meal.id, resident_id: other.id, community_id: community.id,
                              amount: BigDecimal('30'), no_cost: false }])
        end
      ]
      writes.each do |write|
        with_repair_bypass do
          write.call
          codes << described_class::Rows.of(meal).seen
          raise ActiveRecord::Rollback
        end
      end

      expect(codes.uniq.size).to eq(writes.size + 1)
    end

    # A column the page does not show changes nothing: a row's time
    # stamps, and an eater's or a guest's late and vegetarian flags. Each
    # write is a repair from psql, as above.
    it 'stays the same when only what the page does not show changes', prosopite: false do
      with_repair_bypass do
        Guest.insert_all!([{ meal_id: meal.id, resident_id: eater.id, multiplier: Multiplier::FULL }])
      end
      code = described_class::Rows.of(meal).seen
      writes = [
        -> { Bill.where(meal: meal).update_all(updated_at: 1.day.ago) },
        -> { MealResident.where(meal: meal).update_all(late: true, vegetarian: true) },
        -> { Guest.where(meal: meal).update_all(late: true, vegetarian: true) }
      ]
      codes = writes.map do |write|
        with_repair_bypass do
          write.call
          described_class::Rows.of(meal).seen
        end
      end

      expect(codes).to eq([code] * writes.size)
    end

    # The same short code for any dinner, so the hidden field does not
    # grow with the number of rows.
    it 'is a SHA-256 code in hex' do
      expect(described_class::Rows.of(meal).seen).to match(/\A\h{64}\z/)
    end

    it 'reads only the rows of its own dinner' do
      dinner = create(:meal, community: community, date: latest - 2)
      create(:bill, meal: dinner, resident: zed, community: community, amount: BigDecimal('10'))
      create(:meal_resident, meal: dinner, resident: other, community: community)
      create(:guest, meal: dinner, resident: other)
      rows = described_class::Rows.of(meal)

      expect([rows.bills, rows.eaters, rows.guests].map { |list| list.map(&:meal_id).uniq })
        .to eq([[meal.id], [meal.id], []])
    end

    it 'is the same for a form opened after the dinner changed, which reads as usual' do
      correct_zed_to('25')

      expect(edits(cooks(zed: { amount: '20' })).sole).to include('from' => { 'amount' => '25.0', 'no_cost' => false },
                                                                  'to' => { 'amount' => '20.0', 'no_cost' => false })
    end
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
    form = opened({ 'cooks' => { blank.id.to_s => { 'amount' => '', 'no_cost' => '1' } } }, dinner: dinner.reload)

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
      form = opened(values)
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
