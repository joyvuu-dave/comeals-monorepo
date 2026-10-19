# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('db/migrate/20261012120000_move_a_receipt_saved_on_the_wrong_day.rb')

# The data migration that moves one cook's receipt from the empty meal
# where it was typed to the dinner it was for. Nobody signed up for the
# meal where it was typed, so the receipt could never be charged to
# anyone, and a settlement holds such a meal back for good. On the dinner
# it was for, the people who ate pay for it, and the cook is paid back.
RSpec.describe MoveAReceiptSavedOnTheWrongDay do
  let(:migration) { described_class.new }
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:baker) { person('Hana Baker') }
  let(:wrong_day) do
    create(:meal, community: community, date: described_class::FROM, closed: true,
                  description: 'dessert for progressive dinner 12/7')
  end
  let(:dinner) { create(:meal, community: community, date: described_class::TO, description: 'Progressive Dinner') }
  let!(:receipt) { create(:bill, meal: wrong_day, resident: baker, community: community, amount: BigDecimal('20.22')) }
  let!(:other_cook) { create(:bill, meal: dinner, resident: person('Ann Cook'), community: community, amount: 30) }

  before do
    create(:meal_resident, meal: dinner, resident: person('Eli Eater'), community: community)
    create(:meal_resident, meal: dinner, resident: person('Fay Eater'), community: community)
  end

  def person(name)
    create(:resident, community: community, unit: unit, name: name)
  end

  # What the migration prints, which the release log keeps.
  def migrate(direction)
    out = StringIO.new
    $stdout = out
    migration.migrate(direction)
    out.string
  ensure
    $stdout = STDOUT
  end

  def fix_rows
    Audited::Audit.where(auditable_type: 'Bill', comment: described_class::COMMENT)
  end

  def moved
    Bill.find_by(meal: dinner, resident: baker)
  end

  describe 'up' do
    it 'moves the receipt to the dinner it was for, for the same cook and amount' do
      migrate(:up)

      expect(wrong_day.reload.bills).to be_empty
      expect(moved).to have_attributes(amount: BigDecimal('20.22'), no_cost: false, community_id: community.id)
      expect(other_cook.reload.amount).to eq(BigDecimal('30'))
    end

    it 'counts the receipt in the dinner, so the people who ate pay for it and the cook is paid back' do
      expect { migrate(:up) }.to change { MealCostSummary.for(dinner.reload).total_cost }
        .from(BigDecimal('30')).to(BigDecimal('50.22'))
    end

    it 'moves updated_at on both meals, so the calendar version moves' do
      before = [wrong_day, dinner].map { |meal| meal.reload.updated_at }

      migrate(:up)

      expect([wrong_day, dinner].map { |meal| meal.reload.updated_at }).to all(be > before.max)
    end

    # The meal history of the release before this one (v613) names the
    # maker of a row with ResidentNameShortener.short(audit.user&.name), and
    # raised on a username with no person. These rows have neither.
    it 'writes a delete row on the old meal and a create row on the dinner, by no person' do
      old_version = receipt.audits.maximum(:version)

      migrate(:up)

      removed = fix_rows.find_by!(action: 'destroy')
      added = fix_rows.find_by!(action: 'create')
      expect(removed).to have_attributes(auditable_id: receipt.id, version: old_version + 1,
                                         associated_type: 'Meal', associated_id: wrong_day.id)
      expect(added).to have_attributes(auditable_id: moved.id, version: 1, associated_type: 'Meal',
                                       associated_id: dinner.id)
      expect(added.audited_changes).to eq('amount' => '20.22', 'meal_id' => dinner.id, 'no_cost' => false,
                                          'resident_id' => baker.id, 'community_id' => community.id)
      expect(removed.audited_changes).to include('resident_id' => baker.id, 'meal_id' => wrong_day.id)
      expect(fix_rows).to all(have_attributes(user_id: nil, user_type: nil, username: nil))
    end

    it 'shows the move in both meal histories, by who did it and in plain words' do
      migrate(:up)

      expect(AuditSerializer.new(wrong_day.reload.total_audits).to_h.first)
        .to include(user_name: 'Automatic fix', description: 'Hana removed as cook')
      expect(AuditSerializer.new(dinner.reload.total_audits).to_h.first)
        .to include(user_name: 'Automatic fix', description: 'Hana added as cook')
    end

    it 'prints what it moved, for the release log' do
      expect(migrate(:up)).to include('Moved the $20.22 receipt of resident ' \
                                      "#{baker.id} from 2025-12-09 to 2025-12-07.")
    end

    it 'takes both meal locks before it writes a bill' do
      statements = []
      callback = ->(*, payload) { statements << payload[:sql] }
      ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') { migrate(:up) }

      lock = statements.index { |sql| sql.include?('FROM meals') && sql.include?('FOR UPDATE') }
      write = statements.index { |sql| sql.start_with?('DELETE FROM bills') }
      expect(lock).not_to be_nil
      expect(write).not_to be_nil
      expect(lock).to be < write
    end

    it 'does nothing, and says so, when the receipt was moved already' do
      migrate(:up)
      before = Bill.order(:id).pluck(:id, :meal_id, :amount)

      expect(migrate(:up)).to include('already on 2025-12-07')
      expect(Bill.order(:id).pluck(:id, :meal_id, :amount)).to eq(before)
      expect(fix_rows.count).to eq(2)
    end

    it 'does nothing on a database that has no meal on the day it was typed on' do
      Bill.where(meal: wrong_day).delete_all
      Meal.where(id: wrong_day.id).delete_all

      expect(migrate(:up)).to include('No meal on 2025-12-09')
      expect(fix_rows).to be_empty
    end

    # Money: a state it does not expect stops the deploy and changes
    # nothing, so a person looks before any number moves.
    {
      'the receipt holds another amount' => -> { receipt.update_columns(amount: BigDecimal('25')) },
      'the receipt is marked No cost' => -> { receipt.update_columns(amount: 0, no_cost: true) },
      'someone signed up for 2025-12-09' => lambda {
        wrong_day.update_columns(closed: false, closed_at: nil)
        create(:meal_resident, meal: wrong_day, resident: person('Gil Late'), community: community)
      },
      'the meal of 2025-12-09 has a second cook' => lambda {
        create(:bill, meal: wrong_day, resident: person('Ivy Two'), community: community, amount: 1)
      },
      'the note on 2025-12-09 does not name 12/7' => -> { wrong_day.update_columns(description: 'dessert') },
      'the cook already has a cost on the dinner' => lambda {
        create(:bill, meal: dinner, resident: baker, community: community, amount: 5)
      },
      'nobody ate at the dinner' => -> { MealResident.where(meal: dinner).delete_all },
      'there is no meal on 2025-12-07' => lambda {
        MealResident.where(meal: dinner).delete_all
        Bill.where(meal: dinner).delete_all
        Meal.where(id: dinner.id).delete_all
      },
      # The CHECK bills_no_cost_means_no_amount, validated by migration
      # 20261010130200 before this one runs, refuses a bill with both No
      # cost and an amount. So this refusal cannot happen in a real run;
      # the CHECK is dropped here (the example's transaction puts it back)
      # to show the guard still holds without it.
      'the receipt has its amount and is marked No cost' => lambda {
        ActiveRecord::Base.connection.remove_check_constraint(:bills, name: 'bills_no_cost_means_no_amount')
        receipt.update_columns(no_cost: true)
      },
      'the receipt is gone, and not on the dinner either' => -> { receipt.delete }
    }.each do |state, arrange|
      it "refuses and changes nothing when #{state}" do
        instance_exec(&arrange)
        before = Bill.order(:id).pluck(:id, :meal_id, :resident_id, :amount)

        expect { migrate(:up) }.to raise_error(RuntimeError, /Nothing was changed/)
        expect(Bill.order(:id).pluck(:id, :meal_id, :resident_id, :amount)).to eq(before)
        expect(fix_rows).to be_empty
      end
    end

    it 'refuses and changes nothing when the meal it was typed on is settled' do
      wrong_day.update_columns(closed: false, closed_at: nil)
      create(:meal_resident, meal: wrong_day, resident: person('Gil Late'), community: community)
      settle!(cutoff: described_class::FROM)
      before = Bill.order(:id).pluck(:id, :meal_id, :amount)

      expect { migrate(:up) }.to raise_error(RuntimeError, /the meal of 2025-12-09 is settled/)
      expect(Bill.order(:id).pluck(:id, :meal_id, :amount)).to eq(before)
    end

    it 'refuses and changes nothing when the dinner is settled' do
      settle!(cutoff: described_class::TO)
      before = Bill.order(:id).pluck(:id, :meal_id, :amount)

      expect { migrate(:up) }.to raise_error(RuntimeError, /settled/)
      expect(Bill.order(:id).pluck(:id, :meal_id, :amount)).to eq(before)
    end
  end

  describe 'down' do
    it 'puts the receipt back on the meal it was typed on, with its old id, and removes its rows' do
      old_id = receipt.id
      migrate(:up)

      migrate(:down)

      expect(Bill.where(meal: dinner, resident: baker)).to be_empty
      expect(Bill.find(old_id)).to have_attributes(meal_id: wrong_day.id, resident_id: baker.id,
                                                   amount: BigDecimal('20.22'), no_cost: false)
      expect(fix_rows).to be_empty
    end

    it 'refuses when the moved receipt changed after the move' do
      migrate(:up)
      moved.update!(amount: BigDecimal('21'))

      expect { migrate(:down) }.to raise_error(RuntimeError, /changed after/)
    end

    it 'refuses when the dinner was settled since the move' do
      migrate(:up)
      settle!(cutoff: described_class::TO)

      expect { migrate(:down) }.to raise_error(RuntimeError, /settled since the move/)
      expect(moved).to have_attributes(amount: BigDecimal('20.22'))
    end

    it 'does nothing when up never moved anything' do
      expect(migrate(:down)).to include('nothing to put back')
    end
  end

  it_behaves_like 'a data migration that tries a conflict again', described_class
end
