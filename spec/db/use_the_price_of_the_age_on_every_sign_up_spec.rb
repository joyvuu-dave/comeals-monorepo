# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('db/migrate/20261013120000_use_the_price_of_the_age_on_every_sign_up.rb')

# The data migration that gives each sign-up the price of the resident's
# age on the meal's date, where the resident has a birthday and the saved
# price is a different one, and works out again each settlement that
# holds one. In production: 191 sign-ups of four children whose birthdays
# were entered on 2026-10-12, 26 of them in one settlement.
RSpec.describe UseThePriceOfTheAgeOnEverySignUp do
  let(:migration) { described_class.new }
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:cook) { person('Cora Cook') }
  let(:adult) { person('Abe Adult') }
  # 4 years old until 2025-06-01, then 5: free, then the child price.
  let(:child) { person('Kit Small', birthday: Date.new(2020, 6, 1)) }
  let(:settled) { dinner(Date.new(2024, 3, 1), child_price: Multiplier::HALF) }
  let(:open_meals) { [dinner(Date.new(2025, 5, 1)), dinner(Date.new(2025, 7, 1))] }

  def person(name, birthday: nil)
    create(:resident, community: community, unit: unit, name: name, birthday: birthday)
  end

  # A dinner with a $30 receipt, one adult, and the child at the price
  # given. A sign-up takes the price of the resident's age, so the price
  # is set afterwards, the way the old app saved it.
  def dinner(date, child_price: Multiplier::FULL, eater: child)
    meal = create(:meal, community: community, date: date)
    create(:bill, meal: meal, resident: cook, community: community, amount: 30)
    create(:meal_resident, meal: meal, resident: adult, community: community)
    create(:meal_resident, meal: meal, resident: eater, community: community).update_columns(multiplier: child_price)
    meal
  end

  def child_prices
    MealResident.where(resident: child).joins(:meal).order('meals.date').pluck(:multiplier)
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
    settled.reload.reconciliation
  end

  # A balance of $0 has no row, so a person missing from the table is at 0.
  def balances
    Hash.new(BigDecimal('0')).merge(settlement.reconciliation_balances.pluck(:resident_id, :amount).to_h)
  end

  # The production facts the migration checks, for the one child here.
  before do
    stub_const("#{described_class}::PEOPLE", 1)
    stub_const("#{described_class}::SETTLED_SIGN_UPS", 1)
    settled
    settle!(cutoff: Date.new(2024, 3, 2))
    open_meals
  end

  describe 'up' do
    it "gives each sign-up the price of the child's age on its meal's date, and changes no other" do
      migrate(:up)

      expect(child_prices).to eq([Multiplier::FREE, Multiplier::FREE, Multiplier::HALF])
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

    it 'records one correction, for the settled sign-up only, with a reason that names no one' do
      before = balances

      migrate(:up)

      correction = SettlementCorrection.sole
      expect(correction.reason).to eq("Sign-ups saved at a price other than the price of the person's age on the " \
                                      "meal's date: 1. These numbers use the price of the age, from the birthday.")
      expect(correction.lines.pluck(:resident_id, :old_amount, :new_amount).sort)
        .to eq([[adult.id, before[adult.id], balances[adult.id]], [child.id, before[child.id], 0]].sort)
    end

    it 'writes one audit row per sign-up, by no person, and the meal history names both prices' do
      migrate(:up)

      rows = fix_rows.order(:associated_id).to_a
      expect(rows.map { |row| [row.associated_id, row.action, row.audited_changes] })
        .to eq([[settled.id, 'update', { 'multiplier' => [1, 0] }],
                [open_meals.first.id, 'update', { 'multiplier' => [2, 0] }],
                [open_meals.last.id, 'update', { 'multiplier' => [2, 1] }]])
      expect(rows).to all(have_attributes(user_id: nil, username: nil))
      expect(AuditSerializer.new(open_meals.first.reload.total_audits).to_h.first)
        .to include(user_name: 'Automatic fix', description: 'Kit: Adult to Child (free)')
    end

    it 'prints one line for each person, price change and settlement, for the release log' do
      out = migrate(:up)

      expect(out).to include("resident #{child.id}  1 sign-up(s) in settlement #{settlement.id}, " \
                             '2024-03-01 to 2024-03-01  Child to Child (free)')
      expect(out).to include("resident #{child.id}  1 sign-up(s) not settled, 2025-05-01 to 2025-05-01  " \
                             'Adult to Child (free)')
      expect(out).to include("resident #{child.id}  1 sign-up(s) not settled, 2025-07-01 to 2025-07-01  " \
                             'Adult to Child')
      expect(out).to include("Worked out settlement #{settlement.id} again for its 1 sign-up(s): 2 balance(s) changed.")
    end

    it 'does nothing, and says so, when no sign-up matches' do
      migrate(:up)

      expect(migrate(:up)).to include('No sign-up of a person with a birthday is at a price other than')
      expect(SettlementCorrection.count).to eq(1)
    end

    # The age the way Resident#age_on counts it: a year is added on the
    # birthday itself.
    it 'counts a birthday on the meal day itself as the new age' do
      day_before = dinner(Date.new(2025, 5, 31))
      birthday = dinner(Date.new(2025, 6, 1), child_price: Multiplier::FREE)

      migrate(:up)

      expect(MealResident.find_by!(meal: day_before, resident: child).multiplier).to eq(Multiplier::FREE)
      expect(MealResident.find_by!(meal: birthday, resident: child).multiplier).to eq(Multiplier::HALF)
      expect([day_before, birthday].map { |meal| child.multiplier_on(meal.date) })
        .to eq([Multiplier::FREE, Multiplier::HALF])
    end

    it 'leaves a person with no birthday, and every meal before 2018-05-03, as they are' do
      older = person('Ola Older', birthday: Date.new(2014, 1, 1))
      april = dinner(Date.new(2018, 4, 30), eater: older)
      no_birthday = person('Nell None')
      later = dinner(Date.new(2025, 8, 1), child_price: Multiplier::HALF, eater: no_birthday)

      migrate(:up)

      expect(MealResident.find_by!(meal: april, resident: older).multiplier).to eq(Multiplier::FULL)
      expect(MealResident.find_by!(meal: later, resident: no_birthday).multiplier).to eq(Multiplier::HALF)
    end

    # Money: a state it does not expect stops the deploy and changes
    # nothing, so a person looks before any number moves.
    it 'refuses and changes nothing when the sign-ups of someone else would change too' do
      other = person('Ora Other', birthday: Date.new(2021, 1, 1))
      later = dinner(Date.new(2025, 9, 1), eater: other)

      expect { migrate(:up) }.to raise_error(RuntimeError, /sign-ups of 2 people, not 1. Nothing was changed/)
      expect(MealResident.find_by!(meal: later, resident: other).multiplier).to eq(Multiplier::FULL)
      expect(child_prices).to eq([Multiplier::HALF, Multiplier::FULL, Multiplier::FULL])
    end

    it 'refuses and changes nothing when the settled sign-ups are not the ones expected' do
      stub_const("#{described_class}::SETTLED_SIGN_UPS", 2)

      expect { migrate(:up) }.to raise_error(RuntimeError, /1 of them are settled, in 1 settlement\(s\), not 2 in 1/)
      expect(SettlementCorrection.count).to eq(0)
    end

    it 'takes back the correction when a later step fails' do
      allow(migration).to receive(:write_rows).and_raise(RuntimeError, 'a later step failed')

      expect { migrate(:up) }.to raise_error(RuntimeError, 'a later step failed')
      expect(SettlementCorrection.count).to eq(0)
      expect(child_prices).to eq([Multiplier::HALF, Multiplier::FULL, Multiplier::FULL])
    end

    it 'refuses and changes nothing when the settlement already disagrees with its rows' do
      SettledWrites.with_repair_bypass { Bill.where(meal: settled).update_all(amount: 31) }

      expect { migrate(:up) }.to raise_error(Settlement::EarlierDifference)
      expect(child_prices).to eq([Multiplier::HALF, Multiplier::FULL, Multiplier::FULL])
      expect(fix_rows).to be_empty
    end
  end

  describe 'down' do
    it 'puts the old prices back, works the settlement out again with a correction of its own, and removes its rows' do
      before = balances
      migrate(:up)

      migrate(:down)

      expect(child_prices).to eq([Multiplier::HALF, Multiplier::FULL, Multiplier::FULL])
      expect(balances).to eq(before)
      expect(balances[child.id]).to eq(-10)
      expect(SettlementCorrection.order(:id).last.reason).to start_with('Migration 20261013120000 was rolled back')
      expect(fix_rows).to be_empty
    end

    it 'refuses when a sign-up it changed changed again since' do
      migrate(:up)
      row = MealResident.find_by!(meal: open_meals.first, resident: child)
      row.update_columns(multiplier: Multiplier::HALF, updated_at: 1.minute.from_now)

      expect { migrate(:down) }.to raise_error(RuntimeError, /changed since/)
      expect(child_prices).to eq([Multiplier::FREE, Multiplier::HALF, Multiplier::HALF])
    end
  end
end
