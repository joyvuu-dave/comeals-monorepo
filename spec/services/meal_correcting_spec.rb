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
  end

  describe 'what it refuses' do
    it 'refuses an open dinner, which is changed directly' do
      open = create(:meal, community: community, date: latest - 1)

      expect do
        described_class.save!(open, by: admin, reason: 'x') { |edits| edits.add_eater(eater) }
      end.to raise_error(described_class::NotSettled)
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
      expect { save!(reason: ' ') { |edits| edits.cost(cook, amount: BigDecimal('20'), no_cost: false) } }
        .to raise_error(ActiveRecord::RecordInvalid, /Reason can't be blank/)
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

  describe 'the preview' do
    it 'says what the save would change, and saves nothing' do
      result = described_class.preview(meal) { |edits| edits.cost(cook, amount: BigDecimal('20'), no_cost: false) }

      expect(result.changes).to eq(cook.id => BigDecimal('-10'), eater.id => BigDecimal('10'))
      expect(meal.bills.sole.amount).to eq(BigDecimal('30'))
      expect(MealCorrection.count).to eq(0)
      expect(meal.bills.sole.audits.where(action: 'update')).not_to exist
    end

    it 'saves what it showed when nothing changed in between' do
      edit = ->(edits) { edits.cost(cook, amount: BigDecimal('20'), no_cost: false) }
      result = described_class.preview(meal, &edit)

      correction = save!(fingerprint: result.fingerprint, &edit)

      expect(lines_of(correction)).to eq(result.changes)
    end

    it 'refuses the save, and saves nothing, when the dinner changed after the preview' do
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
end
