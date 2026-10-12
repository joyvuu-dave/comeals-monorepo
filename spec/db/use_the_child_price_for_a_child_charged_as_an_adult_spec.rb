# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('db/migrate/20261012120400_use_the_child_price_for_a_child_charged_as_an_adult.rb')

# The data migration that changes sign-ups of a child under 5 from the
# adult price to the child price, on meals before free meals for small
# children began (2018-05-03), and works their settlement out again. In
# production: 13 meals in spring 2018, between 57 at the child price and
# the first free ones, all in one settlement.
RSpec.describe UseTheChildPriceForAChildChargedAsAnAdult do
  let(:migration) { described_class.new }
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:cook) { person('Cora Cook') }
  let(:adult) { person('Abe Adult') }
  let(:child) { person('Kit Small', birthday: Date.new(2015, 1, 15)) }
  let(:earlier) { dinner(Date.new(2018, 3, 1), child_price: Multiplier::HALF) }
  let(:wrong) { [dinner(Date.new(2018, 3, 22)), dinner(Date.new(2018, 4, 29))] }

  def person(name, birthday: nil)
    create(:resident, community: community, unit: unit, name: name, birthday: birthday)
  end

  # A dinner with a $30 receipt, one adult, and the child at the price
  # given. A sign-up takes the price of the resident's age, so the price
  # is set afterwards, the way the old app saved it.
  def dinner(date, child_price: Multiplier::FULL)
    meal = create(:meal, community: community, date: date)
    create(:bill, meal: meal, resident: cook, community: community, amount: 30)
    create(:meal_resident, meal: meal, resident: adult, community: community)
    create(:meal_resident, meal: meal, resident: child, community: community).update_columns(multiplier: child_price)
    meal
  end

  def child_rows
    MealResident.where(resident: child).joins(:meal).order('meals.date')
  end

  def migrate(direction)
    out = StringIO.new
    $stdout = out
    migration.migrate(direction)
    out.string
  ensure
    $stdout = STDOUT
  end

  def fix_rows
    Audited::Audit.where(auditable_type: 'MealResident', comment: described_class::COMMENT)
  end

  def settlement
    earlier.reload.reconciliation
  end

  def balances
    settlement.reconciliation_balances.pluck(:resident_id, :amount).to_h
  end

  before do
    earlier
    wrong
    settle!(cutoff: Date.new(2018, 4, 30))
  end

  describe 'up' do
    it 'changes the adult price to the child price on those meals, and on no other' do
      migrate(:up)

      expect(child_rows.pluck(:multiplier)).to eq([Multiplier::HALF, Multiplier::HALF, Multiplier::HALF])
      expect(MealResident.where(resident: adult).pluck(:multiplier).uniq).to eq([Multiplier::FULL])
    end

    it 'works the settlement out again, so the child pays less, the adult pays more, and the check passes' do
      before = balances

      migrate(:up)

      after = balances
      expect(after[child.id]).to be > before[child.id]
      expect(after[adult.id]).to be < before[adult.id]
      expect(after[cook.id]).to eq(before[cook.id])
      expect(after.values.sum).to eq(0)
      expect(LedgerVerification.call).to be_passed
    end

    it 'records the correction, with a reason that names no one, and each balance before and after' do
      before = balances

      migrate(:up)

      correction = SettlementCorrection.sole
      expect(correction.reason).to eq('2 sign-ups for a child under 5 were saved at the adult price. These numbers ' \
                                      'use the child price, which the same child paid on every meal before.')
      expect(correction.lines.pluck(:resident_id, :old_amount, :new_amount).sort)
        .to eq([[adult.id, before[adult.id], balances[adult.id]], [child.id, before[child.id], balances[child.id]]])
    end

    it 'writes one audit row per sign-up, by no person, and the meal history says Adult to Child' do
      versions = wrong.map { |meal| MealResident.find_by!(meal: meal, resident: child).audits.maximum(:version) }

      migrate(:up)

      rows = fix_rows.order(:associated_id).to_a
      expect(rows.map { |row| [row.associated_id, row.version, row.action, row.audited_changes] })
        .to eq(wrong.each_with_index.map { |meal, i| [meal.id, versions[i] + 1, 'update', { 'multiplier' => [2, 1] }] })
      expect(rows).to all(have_attributes(user_id: nil, username: nil))
      expect(AuditSerializer.new(wrong.first.reload.total_audits).to_h.first)
        .to include(user_name: 'Automatic fix', description: 'Kit: Adult to Child')
    end

    it 'prints each sign-up and the settlement it worked out again, for the release log' do
      out = migrate(:up)

      expect(out).to include("2018-03-22  resident #{child.id}  Adult to Child")
      expect(out).to include("Worked out settlement #{settlement.id} again for its 2 sign-up(s): 2 balance(s) changed.")
    end

    it 'does nothing, and says so, when no sign-up matches' do
      migrate(:up)

      expect(migrate(:up)).to include('No sign-up of a child under 5 is at the adult price')
      expect(SettlementCorrection.count).to eq(1)
    end

    # Both open meals: rows outside the rule are never touched, settled or not.
    it 'leaves a child who was 5 or older, and a meal from 2018-05-03 on, at the adult price' do
      older = person('Ola Older', birthday: Date.new(2013, 1, 1))
      april = create(:meal, community: community, date: Date.new(2018, 4, 30))
      create(:bill, meal: april, resident: cook, community: community, amount: 30)
      create(:meal_resident, meal: april, resident: older, community: community)
        .update_columns(multiplier: Multiplier::FULL)
      may = dinner(Date.new(2018, 5, 3))

      migrate(:up)

      expect(MealResident.find_by!(meal: april, resident: older).multiplier).to eq(Multiplier::FULL)
      expect(MealResident.find_by!(meal: may, resident: child).multiplier).to eq(Multiplier::FULL)
    end

    # Money: a state it does not expect stops the deploy and changes
    # nothing, so a person looks before any number moves.
    it 'refuses and changes nothing when the child paid the adult price before too' do
      MealResident.find_by!(meal: earlier, resident: child).tap do |row|
        SettledWrites.with_repair_bypass { row.update_columns(multiplier: Multiplier::FULL) }
      end
      before = balances

      expect { migrate(:up) }.to raise_error(RuntimeError, /Nothing was changed/)
      expect(balances).to eq(before)
      expect(fix_rows).to be_empty
    end

    it 'refuses and changes nothing when one of those meals is not settled' do
      open_meal = dinner(Date.new(2018, 4, 30))
      before = balances

      expect { migrate(:up) }.to raise_error(RuntimeError, /not settled/)
      expect(MealResident.find_by!(meal: open_meal, resident: child).multiplier).to eq(Multiplier::FULL)
      expect(balances).to eq(before)
    end

    it 'refuses and changes nothing when the settlement already disagrees with its rows' do
      SettledWrites.with_repair_bypass { Bill.where(meal: earlier).update_all(amount: 31) }

      expect { migrate(:up) }.to raise_error(Settlement::EarlierDifference)
      expect(child_rows.pluck(:multiplier)).to eq([Multiplier::HALF, Multiplier::FULL, Multiplier::FULL])
      expect(fix_rows).to be_empty
    end
  end

  describe 'down' do
    it 'puts the adult price back, works the settlement out again with a correction of its own, and removes its rows' do
      before = balances
      migrate(:up)

      migrate(:down)

      expect(child_rows.pluck(:multiplier)).to eq([Multiplier::HALF, Multiplier::FULL, Multiplier::FULL])
      expect(balances).to eq(before)
      expect(SettlementCorrection.order(:id).last.reason).to start_with('Migration 20261012120400 was rolled back')
      expect(fix_rows).to be_empty
    end

    it 'refuses when a sign-up it changed changed again since' do
      migrate(:up)
      row = MealResident.find_by!(meal: wrong.first, resident: child)
      SettledWrites.with_repair_bypass { row.update_columns(multiplier: Multiplier::FREE, updated_at: 1.minute.from_now) }

      expect { migrate(:down) }.to raise_error(RuntimeError, /changed since/)
    end
  end
end
