# frozen_string_literal: true

require 'rails_helper'

# Correcting a settled dinner (ADR 0011 rule 6): the dinner's rows change,
# with history, and each person's change is recorded as a line. The
# settlement that carries a correction, the running balances and the
# nightly check are in settlement_carries_corrections_spec.rb; the
# database's own rules are in spec/db/meal_corrections_triggers_spec.rb.
RSpec.describe MealCorrecting do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:latest) { Reconciliation.latest_cutoff(community.today) }
  let(:admin) { create(:admin_user, community: community, superuser: true) }
  let(:cook) { create(:resident, community: community, unit: unit, name: 'Cook') }
  let(:eater) { create(:resident, community: community, unit: unit, name: 'Eater') }
  let(:other) { create(:resident, community: community, unit: unit, name: 'Other') }

  # A dinner settled with one cook ($30) and one eater: the cook is
  # credited $30 and the eater charged $30.
  let!(:meal) do
    create(:meal, community: community, date: latest).tap do |meal|
      create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('30'))
      create(:meal_resident, meal: meal, resident: eater, community: community)
      settle!(cutoff: latest)
      meal.reload
    end
  end

  def save!(reason: 'Typed the wrong amount', fingerprint: nil, &)
    described_class.save!(meal, by: admin, reason: reason, fingerprint: fingerprint, &)
  end

  def lines_of(correction)
    correction.lines.pluck(:resident_id, :amount).to_h
  end

  describe 'saving a correction' do
    it 'changes the cost, records what changed, and each person\'s change' do
      correction = save! { |edits| edits.cost(cook, amount: BigDecimal('20'), no_cost: false) }

      expect(meal.bills.sole.amount).to eq(BigDecimal('20'))
      expect(correction).to have_attributes(meal: meal, admin_user: admin, reason: 'Typed the wrong amount',
                                            reconciliation_id: nil)
      expect(correction.edits).to eq([{ 'what' => 'cost', 'resident_id' => cook.id,
                                        'from' => { 'amount' => '30.0', 'no_cost' => false },
                                        'to' => { 'amount' => '20.0', 'no_cost' => false } }])
      # The cook is credited $10 less, and the eater charged $10 less.
      expect(lines_of(correction)).to eq(cook.id => BigDecimal('-10'), eater.id => BigDecimal('10'))
    end

    it 'records the admin in the history of each row it changed' do
      save! { |edits| edits.cost(cook, amount: BigDecimal('20'), no_cost: false) }

      expect(meal.bills.sole.audits.last).to have_attributes(user: admin, action: 'update')
    end

    it 'leaves the old settlement as it was settled' do
      reconciliation = meal.reconciliation
      expect { save! { |edits| edits.cost(cook, amount: BigDecimal('20'), no_cost: false) } }
        .not_to(change { [reconciliation.reconciliation_balances.pluck(:resident_id, :amount).sort, MealCharge.count] })
      expect(meal.reload.reconciliation_id).to eq(reconciliation.id)
    end

    it 'adds and removes cooks' do
      correction = save! do |edits|
        edits.cost(other, amount: BigDecimal('12'), no_cost: false)
        edits.remove_cook(cook)
      end

      expect(meal.bills.pluck(:resident_id, :amount)).to eq([[other.id, BigDecimal('12')]])
      expect(correction.edits.pluck('resident_id', 'from', 'to')).to eq(
        [[other.id, nil, { 'amount' => '12.0', 'no_cost' => false }],
         [cook.id, { 'amount' => '30.0', 'no_cost' => false }, nil]]
      )
      expect(lines_of(correction)).to eq(cook.id => BigDecimal('-30'), other.id => BigDecimal('12'),
                                         eater.id => BigDecimal('18'))
    end

    it 'adds an eater at their price for the dinner\'s date, and removes one' do
      child = create(:resident, community: community, unit: unit, multiplier: 1)

      correction = save! do |edits|
        edits.add_eater(child)
        edits.remove_eater(eater)
      end

      expect(meal.meal_residents.pluck(:resident_id, :multiplier)).to eq([[child.id, 1]])
      expect(correction.edits.pluck('what', 'resident_id', 'from', 'to'))
        .to eq([['eater', child.id, nil, 1], ['eater', eater.id, 2, nil]])
      expect(lines_of(correction)).to eq(eater.id => BigDecimal('30'), child.id => BigDecimal('-30'))
    end

    # The price was wrong when they signed up: here, a birthday fixed later.
    it 'sets an eater\'s price to their price for the dinner\'s date by today\'s rule' do
      eater.update!(birthday: meal.date - 8.years, kind: 'child')

      correction = save! { |edits| edits.reprice_eater(eater) }

      expect(meal.meal_residents.sole.multiplier).to eq(1)
      expect(correction.edits).to eq([{ 'what' => 'eater', 'resident_id' => eater.id, 'from' => 2, 'to' => 1 }])
      # Still the only eater, so still charged the whole $30.
      expect(correction.lines).to be_empty
    end

    # $30 shared by four units: the eater (two) and Other's guest (two).
    # After: the eater's own two and the eater's child guest's one, so the
    # eater is charged all $30 and Other nothing.
    it 'adds and removes guests' do
      dinner = create(:meal, community: community, date: latest - 1)
      create(:bill, meal: dinner, resident: cook, community: community, amount: BigDecimal('30'))
      create(:meal_resident, meal: dinner, resident: eater, community: community)
      guest = create(:guest, meal: dinner, resident: other, multiplier: 2)
      settle!(cutoff: latest)

      correction = described_class.save!(dinner.reload, by: admin, reason: 'The guest was the eater\'s') do |edits|
        edits.remove_guest(guest)
        edits.add_guest(eater, multiplier: 1)
      end

      expect(dinner.guests.pluck(:resident_id, :multiplier)).to eq([[eater.id, 1]])
      expect(correction.edits.pluck('what', 'resident_id', 'from', 'to'))
        .to eq([['guest', other.id, 2, nil], ['guest', eater.id, nil, 1]])
      expect(lines_of(correction)).to eq(eater.id => BigDecimal('-15'), other.id => BigDecimal('15'))
    end

    it 'records a correction that moves no money, with no lines' do
      correction = save! { |edits| edits.cost(other, amount: BigDecimal('0'), no_cost: true) }

      expect(correction.edits.sole['to']).to eq('amount' => '0.0', 'no_cost' => true)
      expect(correction.lines).to be_empty
    end

    it 'changes a cost to No cost, and the row says No cost' do
      correction = save! { |edits| edits.cost(cook, amount: BigDecimal('0'), no_cost: true) }

      expect(meal.bills.sole).to have_attributes(amount: BigDecimal('0'), no_cost: true)
      expect(correction.edits.sole['to']).to eq('amount' => '0.0', 'no_cost' => true)
      expect(lines_of(correction)).to eq(cook.id => BigDecimal('-30'), eater.id => BigDecimal('30'))
    end

    # The admin form loads the dinner when the request starts. A settlement
    # can commit after that, in another process. The correction reads the
    # dinner again when it takes the dinner's lock, so it works from the
    # row as it is now, not from the copy it was given.
    it 'reads the dinner again under its lock, so a copy loaded before the settlement still corrects' do
      dinner = create(:meal, community: community, date: latest - 1)
      create(:bill, meal: dinner, resident: cook, community: community, amount: BigDecimal('30'))
      create(:meal_resident, meal: dinner, resident: eater, community: community)
      loaded_before = Meal.find(dinner.id)
      settle!(cutoff: latest)

      correction = described_class.save!(loaded_before, by: admin, reason: 'Typed $30 for $20') do |edits|
        edits.cost(cook, amount: BigDecimal('20'), no_cost: false)
      end

      expect(lines_of(correction)).to eq(cook.id => BigDecimal('-10'), eater.id => BigDecimal('10'))
    end

    # A settled dinner can be closed too. A correction changes its
    # sign-ups and guests all the same (admin_correction). Each person here
    # also has a row on another dinner, made first, and the row each edit
    # removes is not the first row on this dinner. So an edit that found
    # its row by the person alone, or by the dinner alone, would change the
    # wrong row.
    it 'corrects the sign-ups and guests of a closed dinner, and only that dinner\'s rows' do
      kid = create(:resident, community: community, unit: unit, name: 'Kid')
      leaver = create(:resident, community: community, unit: unit, name: 'Leaver')
      another = create(:meal, community: community, date: community.today + 3)
      [kid, leaver].each { |person| create(:meal_resident, meal: another, resident: person, community: community) }
      dinner = create(:meal, community: community, date: latest - 1)
      create(:bill, meal: dinner, resident: cook, community: community, amount: BigDecimal('36'))
      [eater, kid, leaver].each do |person|
        create(:meal_resident, meal: dinner, resident: person, community: community)
      end
      create(:guest, meal: dinner, resident: eater, multiplier: 2)
      gone = create(:guest, meal: dinner, resident: eater, multiplier: 1)
      dinner.update!(closed: true)
      settle!(cutoff: latest)
      kid.update!(birthday: dinner.date - 8.years, kind: 'child')

      correction = described_class.save!(dinner.reload, by: admin, reason: 'Leaver was away') do |edits|
        edits.remove_eater(leaver)
        edits.remove_guest(gone)
        edits.reprice_eater(kid)
        edits.add_eater(other)
        edits.add_guest(other, multiplier: 1)
      end

      expect(dinner.meal_residents.order(:resident_id).pluck(:resident_id, :multiplier))
        .to eq([[eater.id, 2], [kid.id, 1], [other.id, 2]])
      expect(dinner.guests.order(:resident_id).pluck(:resident_id, :multiplier)).to eq([[eater.id, 2], [other.id, 1]])
      expect(another.meal_residents.order(:resident_id).pluck(:resident_id)).to eq([kid.id, leaver.id])
      expect(correction.edits.pluck('what', 'resident_id', 'from', 'to'))
        .to eq([['eater', leaver.id, 2, nil], ['guest', eater.id, 1, nil], ['eater', kid.id, 2, 1],
                ['eater', other.id, nil, 2], ['guest', other.id, nil, 1]])
      # $36 over 9 units ($4 each) before, over 8 units ($4.50 each) after.
      expect(lines_of(correction)).to eq(eater.id => BigDecimal('2'), kid.id => BigDecimal('3.5'),
                                         leaver.id => BigDecimal('8'), other.id => BigDecimal('-13.5'))
    end

    # The same for costs: each cook also cooked another dinner, made first,
    # and the cook removed is not the first cook on this dinner.
    it 'changes and removes the costs of this dinner only' do
      helper = create(:resident, community: community, unit: unit, name: 'Helper')
      another = create(:meal, community: community, date: community.today + 3)
      create(:bill, meal: another, resident: helper, community: community, amount: BigDecimal('10'))
      dinner = create(:meal, community: community, date: latest - 1)
      create(:bill, meal: dinner, resident: cook, community: community, amount: BigDecimal('30'))
      create(:bill, meal: dinner, resident: helper, community: community, amount: BigDecimal('6'))
      create(:meal_resident, meal: dinner, resident: eater, community: community)
      settle!(cutoff: latest)

      correction = described_class.save!(dinner.reload, by: admin, reason: 'Helper bought nothing') do |edits|
        edits.remove_cook(helper)
        edits.cost(cook, amount: BigDecimal('24'), no_cost: false)
      end

      expect(dinner.bills.pluck(:resident_id, :amount)).to eq([[cook.id, BigDecimal('24')]])
      expect(another.bills.pluck(:resident_id, :amount)).to eq([[helper.id, BigDecimal('10')]])
      expect(meal.bills.pluck(:resident_id, :amount)).to eq([[cook.id, BigDecimal('30')]])
      expect(lines_of(correction)).to eq(cook.id => BigDecimal('-6'), helper.id => BigDecimal('-6'),
                                         eater.id => BigDecimal('12'))
    end
  end

  describe 'what it refuses' do
    it 'refuses an open dinner, which is changed directly' do
      open = create(:meal, community: community, date: latest - 1)

      expect do
        described_class.save!(open, by: admin, reason: 'x') { |edits| edits.add_eater(eater) }
      end.to raise_error(described_class::NotSettled,
                         "Meal #{open.id} is not settled. An open dinner is changed directly.")
      expect(MealCorrection.count).to eq(0)
      expect(open.meal_residents).to be_empty
    end

    it 'refuses a price that is already the price for the eater\'s age, as changing nothing' do
      expect { save! { |edits| edits.reprice_eater(eater) } }.to raise_error(described_class::NothingChanged)
    end

    it 'refuses a correction that changes nothing' do
      expect { save! { |edits| edits.cost(cook, amount: BigDecimal('30'), no_cost: false) } }
        .to raise_error(described_class::NothingChanged)
      expect(MealCorrection.count).to eq(0)
    end

    it 'refuses a blank reason before it changes any row' do
      edited = false
      expect do
        save!(reason: ' ') do |edits|
          edited = true
          edits.cost(cook, amount: BigDecimal('20'), no_cost: false)
        end
      end.to raise_error(ActiveRecord::RecordInvalid, /Reason can't be blank/)
      expect(edited).to be(false)
      expect(meal.bills.sole.amount).to eq(BigDecimal('30'))
    end

    it 'refuses an edit the model refuses, and keeps nothing' do
      expect do
        save! do |edits|
          edits.add_eater(other)
          edits.cost(cook, amount: BigDecimal('20.001'), no_cost: false)
        end
      end.to raise_error(ActiveRecord::RecordInvalid, /must be whole cents/)
      expect(meal.meal_residents.pluck(:resident_id)).to eq([eater.id])
      expect(MealCorrection.count).to eq(0)
    end

    # The correction runs in a savepoint of its own. A caller that has a
    # transaction open, and goes on after the refusal, keeps none of the
    # correction's edits either.
    it 'keeps nothing of a refused correction inside a caller\'s transaction' do
      ActiveRecord::Base.transaction do
        expect do
          save! do |edits|
            edits.add_eater(other)
            edits.cost(cook, amount: BigDecimal('20.001'), no_cost: false)
          end
        end.to raise_error(ActiveRecord::RecordInvalid, /must be whole cents/)
        expect(meal.meal_residents.pluck(:resident_id)).to eq([eater.id])
      end
    end

    # Rows are found on the dinner being corrected, so a row of another
    # dinner is not one this correction can remove.
    it 'refuses to remove a guest of another dinner, and leaves it there' do
      guest = create(:guest, meal: create(:meal, community: community, date: community.today + 3), resident: other)

      expect { save! { |edits| edits.remove_guest(guest) } }.to raise_error(ActiveRecord::RecordNotFound)
      expect(Guest.exists?(guest.id)).to be(true)
      expect(MealCorrection.count).to eq(0)
    end

    # Something other than a correction changed the dinner's rows: here,
    # psql with the repair bypass. A correction works from the rows as
    # they are, so it would fold that change in under its own reason.
    it 'refuses a dinner whose rows already differ from what it was settled at' do
      connection = ActiveRecord::Base.connection
      connection.execute("SELECT set_config('comeals.allow_settled_writes', 'on', true)")
      Bill.where(meal_id: meal.id).update_all(amount: BigDecimal('40'))
      connection.execute("SELECT set_config('comeals.allow_settled_writes', '', true)")

      expect { save! { |edits| edits.add_eater(other) } }
        .to raise_error(described_class::EarlierDifference, /already differ .* for 2 people/)
      expect(MealCorrection.count).to eq(0)
    end

    it 'turns the permission off when it is done, so a later write to the dinner is refused' do
      ActiveRecord::Base.transaction do
        save! { |edits| edits.cost(cook, amount: BigDecimal('20'), no_cost: false) }

        row = MealResident.new(meal: Meal.find(meal.id), resident: other)
        row.admin_correction = true
        expect(row.save).to be(false)
        expect(row.errors[:base]).to eq(['Meal has been reconciled.'])
      end
    end
  end

  # A settlement holds back an open dinner with money on a cost and
  # nobody to charge (Meal.receipt_and_nobody_to_charge, ADR 0011 rule 3):
  # settling it would credit the cook $0. A correction must not leave a
  # settled dinner that way either, or the next settlement carries a
  # correction that credits the cook $0 for that money (#172).
  describe 'a cost with nobody to charge' do
    let(:baby) { create(:resident, community: community, unit: unit, multiplier: 0, name: 'Baby') }
    let(:refusal) do
      'This leaves a $30.00 cost with nobody to charge. Keep someone who pays, or mark the cost No cost.'
    end

    # Only a baby ate, and the cook marked No cost, so it settled with no money.
    def free_dinner
      create(:meal, community: community, date: latest - 1).tap do |dinner|
        create(:bill, meal: dinner, resident: cook, community: community, amount: 0, no_cost: true)
        create(:meal_resident, meal: dinner, resident: baby, community: community)
        settle!(cutoff: latest)
      end.reload
    end

    it 'refuses to remove the only person who pays and keep the cost, in the preview and the save' do
      remove = ->(edits) { edits.remove_eater(eater) }

      expect { described_class.preview(meal, &remove) }.to raise_error(described_class::NobodyToCharge, refusal)
      expect { save!(&remove) }.to raise_error(described_class::NobodyToCharge, refusal)
      expect(meal.meal_residents.pluck(:resident_id)).to eq([eater.id])
      expect(MealCorrection.count).to eq(0)
    end

    it 'refuses to add a cost to a dinner only free eaters ate, in the preview and the save' do
      dinner = free_dinner
      add_cost = ->(edits) { edits.cost(cook, amount: BigDecimal('30'), no_cost: false) }

      expect { described_class.preview(dinner, &add_cost) }.to raise_error(described_class::NobodyToCharge, refusal)
      expect do
        described_class.save!(dinner, by: admin, reason: 'Forgot the cost', &add_cost)
      end.to raise_error(described_class::NobodyToCharge, refusal)
      expect(dinner.bills.sole).to have_attributes(amount: 0, no_cost: true)
      expect(MealCorrection.count).to eq(0)
    end

    it 'adds up every cost with money on it' do
      remove = lambda do |edits|
        edits.cost(other, amount: BigDecimal('12.5'), no_cost: false)
        edits.remove_eater(eater)
      end

      expect { save!(&remove) }.to raise_error(described_class::NobodyToCharge, /a \$42\.50 cost/)
    end

    it 'saves a correction that removes the payer and keeps another one' do
      correction = save! do |edits|
        edits.add_eater(other)
        edits.remove_eater(eater)
      end

      expect(lines_of(correction)).to eq(eater.id => BigDecimal('30'), other.id => BigDecimal('-30'))
    end

    it 'saves a correction that removes the payer and marks the cost No cost' do
      correction = save! do |edits|
        edits.cost(cook, amount: BigDecimal('0'), no_cost: true)
        edits.remove_eater(eater)
      end

      expect(lines_of(correction)).to eq(cook.id => BigDecimal('-30'), eater.id => BigDecimal('30'))
    end

    it 'saves a correction that adds a guest to pay for a new cost on a dinner only free eaters ate' do
      dinner = free_dinner
      correction = described_class.save!(dinner, by: admin, reason: 'Forgot the cost and the guest') do |edits|
        edits.cost(cook, amount: BigDecimal('30'), no_cost: false)
        edits.add_guest(cook, multiplier: 2)
      end

      # The cook spent $30 and hosted the one guest who pays: no change.
      expect(correction.lines).to be_empty
    end
  end

  describe 'the preview' do
    it 'says what the save would change, and saves nothing' do
      result = described_class.preview(meal) { |edits| edits.cost(cook, amount: BigDecimal('20'), no_cost: false) }

      expect(result.changes).to eq(cook.id => BigDecimal('-10'), eater.id => BigDecimal('10'))
      # The edits as the save records them, amounts written as text.
      expect(result.edits).to eq([{ 'what' => 'cost', 'resident_id' => cook.id,
                                    'from' => { 'amount' => '30.0', 'no_cost' => false },
                                    'to' => { 'amount' => '20.0', 'no_cost' => false } }])
      expect(meal.bills.sole.amount).to eq(BigDecimal('30'))
      expect(MealCorrection.count).to eq(0)
      expect(meal.bills.sole.audits.where(action: 'update')).not_to exist
    end

    # The preview rolls back a savepoint of its own. A caller that has a
    # transaction open keeps none of its edits either.
    it 'saves nothing inside a caller\'s transaction' do
      ActiveRecord::Base.transaction do
        described_class.preview(meal) { |edits| edits.cost(cook, amount: BigDecimal('20'), no_cost: false) }

        expect(meal.bills.sole.amount).to eq(BigDecimal('30'))
      end
    end

    it 'saves what it showed when nothing changed in between' do
      edit = ->(edits) { edits.cost(cook, amount: BigDecimal('20'), no_cost: false) }
      result = described_class.preview(meal, &edit)

      correction = save!(fingerprint: result.fingerprint, &edit)

      expect(lines_of(correction)).to eq(result.changes)
    end

    # Other is made before the preview. Made inside it, the preview's
    # rollback would take the row back, and the save would add Other again
    # under a new id: the edits would differ, and this would not show that
    # a change in the amounts alone refuses the save.
    it 'refuses the save, and saves nothing, when the dinner changed after the preview' do
      other
      edit = ->(edits) { edits.add_eater(other) }
      result = described_class.preview(meal, &edit)
      described_class.save!(meal, by: admin, reason: 'First') do |edits|
        edits.cost(cook, amount: BigDecimal('24'), no_cost: false)
      end

      expect { save!(fingerprint: result.fingerprint, &edit) }
        .to raise_error(described_class::Changed,
                        'The dinner changed after the preview was made, so nothing was saved.')
      expect(meal.meal_residents.pluck(:resident_id)).to eq([eater.id])
      expect(MealCorrection.count).to eq(1)
    end
  end

  # The code the correction form sends with Save (Result#fingerprint). It
  # is the same for the same edits and changes, and differs when either
  # differs.
  describe 'the code of a preview' do
    let(:cost_edit) do
      [{ 'what' => 'cost', 'resident_id' => 1, 'from' => { 'amount' => '30.0', 'no_cost' => false },
         'to' => { 'amount' => '20.0', 'no_cost' => false } }]
    end

    def code(changes, edits: cost_edit)
      amounts = changes.transform_values { |amount| BigDecimal(amount) }
      described_class::Result.new(edits: edits, changes: amounts).fingerprint
    end

    it 'is short, and the same for the same changes in any order' do
      expect(code({ 1 => '5', 2 => '-5' })).to match(/\A\h{64}\z/)
      expect(code({ 2 => '-5', 1 => '5' })).to eq(code({ 1 => '5', 2 => '-5' }))
    end

    it 'differs when a change differs, names another person, or is not there' do
      codes = [code({ 1 => '5', 2 => '-5' }), code({ 1 => '6', 2 => '-6' }), code({ 1 => '5', 3 => '-5' }), code({})]

      expect(codes.uniq.size).to eq(4)
    end

    # Written one after the other with nothing between, both lists read
    # "1:5.023:-7.025:2.0".
    it 'keeps each person\'s change apart from the next' do
      expect(code({ 1 => '5', 23 => '-7', 25 => '2' })).not_to eq(code({ 1 => '5.02', 3 => '-7.02', 5 => '2' }))
    end

    it 'differs when the edits differ and the changes do not' do
      eater_edit = [{ 'what' => 'eater', 'resident_id' => 1, 'from' => nil, 'to' => 2 }]

      expect(code({ 1 => '5', 2 => '-5' }, edits: eater_edit)).not_to eq(code({ 1 => '5', 2 => '-5' }))
    end
  end
end
