# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('db/migrate/20261013120100_put_back_costs_an_old_cook_form_deleted.rb')

# The data migration that puts back the costs of the BBQ dinner, which an
# old cook form (issue #7) deleted with no record, takes off the two costs
# the form saved there instead, puts the receipt on the pasta dinner it
# was typed for, makes that dinner's other cook No cost, and works the
# settlement out again.
RSpec.describe PutBackCostsAnOldCookFormDeleted do
  let(:migration) { described_class.new }
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:bbq) { create(:meal, community: community, date: described_class::BBQ) }
  let(:pasta) { create(:meal, community: community, date: described_class::PASTA) }
  let(:ribs_cook) { person('Rob Ribs') }
  let(:helper) { person('Hal Helper') }
  let(:dessert_cook) { person('Dee Dessert') }
  let(:pasta_cook) { person('Pat Pasta') }
  let(:second_cook) { person('Sam Second') }
  let(:eaters) { [person('Eli Eater'), person('Fay Eater')] }
  # The costs as they were saved, then deleted with no audit row.
  let!(:deleted) do
    [[ribs_cook, 70], [helper, 0], [dessert_cook, 15]].map do |cook, amount|
      create(:bill, meal: bbq, resident: cook, community: community, amount: 0).tap do |bill|
        bill.update!(amount: amount) unless amount.zero?
      end
    end
  end

  before do
    Bill.where(id: deleted.map(&:id)).delete_all
    create(:bill, meal: bbq, resident: pasta_cook, community: community, amount: described_class::RECEIPT)
    create(:bill, meal: bbq, resident: second_cook, community: community, amount: 0)
    create(:bill, meal: pasta, resident: pasta_cook, community: community, amount: 0)
    create(:bill, meal: pasta, resident: second_cook, community: community, amount: described_class::NOTHING)
    [bbq, pasta].each do |meal|
      eaters.each { |eater| create(:meal_resident, meal: meal, resident: eater, community: community) }
    end
    settle_as_before_rule_3!(cutoff: described_class::PASTA + 1)
  end

  def person(name)
    create(:resident, community: community, unit: unit, name: name)
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
    Audited::Audit.where(auditable_type: 'Bill', comment: described_class::COMMENT)
  end

  def costs(meal)
    meal.bills.order(:resident_id).map { |bill| [bill.resident_id, bill.amount, bill.no_cost] }
  end

  # A balance of $0 has no row, so a person missing from the table is at 0.
  def balances
    Hash.new(BigDecimal('0')).merge(bbq.reload.reconciliation.reconciliation_balances
                                        .pluck(:resident_id, :amount).to_h)
  end

  describe 'up' do
    it 'puts the deleted costs back with their old ids, and moves the receipt to the pasta dinner' do
      migrate(:up)

      expect(costs(bbq)).to eq([[ribs_cook.id, 70, false], [helper.id, 0, true], [dessert_cook.id, 15, false]])
      expect(bbq.bills.pluck(:id)).to match_array(deleted.map(&:id))
      expect(costs(pasta)).to eq([[pasta_cook.id, described_class::RECEIPT, false], [second_cook.id, 0, true]])
    end

    it 'gives each cost it puts back the time of its create row' do
      first_saved = deleted.to_h { |bill| [bill.id, bill.audits.find_by!(action: 'create').created_at.round(6)] }

      migrate(:up)

      expect(bbq.bills.to_h { |bill| [bill.id, bill.created_at.round(6)] }).to eq(first_saved)
    end

    it 'works the settlement out again, so the cooks who paid are credited, and the check passes' do
      before = balances

      migrate(:up)

      after = balances
      expect(after[ribs_cook.id] - before[ribs_cook.id]).to eq(70)
      expect(after[dessert_cook.id] - before[dessert_cook.id]).to eq(15)
      expect(after[second_cook.id] - before[second_cook.id]).to eq(-described_class::NOTHING)
      expect(after[pasta_cook.id]).to eq(before[pasta_cook.id])
      expect(after.values.sum).to eq(0)
      expect(LedgerVerification.call).to be_passed
    end

    it 'records the correction, with a reason that names no one' do
      migrate(:up)

      expect(SettlementCorrection.sole.reason)
        .to eq('An old cook form deleted the three costs of the BBQ dinner of 2019-09-02 and saved the $49.50 ' \
               'receipt of the pasta dinner of 2019-09-05 there. These numbers use the costs the cooks gave: the ' \
               "three back, the receipt on the pasta dinner, and the pasta dinner's other cook at No cost.")
    end

    it 'writes the audit rows a save would write, by no person, after the old rows of each cost' do
      migrate(:up)

      rows = fix_rows.order(:id).map { |row| [row.action, row.auditable_id, row.audited_changes] }
      expect(rows.map(&:first)).to eq(%w[destroy destroy create create create update update])
      expect(rows.find { |row| row[1] == deleted.first.id }.last)
        .to include('amount' => '70.0', 'no_cost' => false, 'meal_id' => bbq.id, 'resident_id' => ribs_cook.id)
      expect(rows.last(2).map(&:last))
        .to eq([{ 'amount' => ['0.0', '49.5'] }, { 'amount' => ['47.58', '0.0'], 'no_cost' => [false, true] }])
      expect(fix_rows).to all(have_attributes(user_id: nil, username: nil))
      expect(Audited::Audit.where(auditable_type: 'Bill', auditable_id: deleted.first.id).order(:id).pluck(:version))
        .to eq([1, 2, 3])
      expect(AuditSerializer.new(pasta.reload.total_audits).to_h.first).to include(user_name: 'Automatic fix')
    end

    it 'reads a last amount saved as cents, the way audit rows before 2026 hold it' do
      Audited::Audit.where(auditable_type: 'Bill', auditable_id: deleted.first.id, action: 'update')
                    .update_all(audited_changes: { 'amount_cents' => [0, 7000] })

      migrate(:up)

      expect(Bill.find(deleted.first.id).amount).to eq(70)
    end

    it 'prints what it did, for the release log' do
      out = migrate(:up)

      expect(out).to include('Put back 3 costs on 2019-09-02 ($70.00, $0.00, $15.00), and moved the $49.50 ' \
                             "receipt to 2019-09-05, where the other cook's $47.58 is now No cost.")
      expect(out).to include("Worked out settlement #{bbq.reload.reconciliation_id} again:")
    end

    it 'does nothing, and says so, when it ran already' do
      migrate(:up)

      expect(migrate(:up)).to include('This migration changed the costs of both dinners already')
      expect(SettlementCorrection.count).to eq(1)
    end

    # Money: a state it does not expect stops the deploy and changes
    # nothing, so a person looks before any number moves.
    it 'refuses and changes nothing when the BBQ dinner does not hold the receipt' do
      SettledWrites.with_repair_bypass { Bill.where(meal: bbq, resident: pasta_cook).update_all(amount: 49) }

      expect { migrate(:up) }.to raise_error(RuntimeError, /Nothing was changed/)
      expect(bbq.bills.count).to eq(2)
      expect(fix_rows).to be_empty
    end

    it 'refuses and changes nothing when a deleted cost was saved at another amount' do
      deleted.last.audits.where(action: 'update').update_all(audited_changes: { 'amount' => ['0.0', '16.0'] })

      expect { migrate(:up) }.to raise_error(RuntimeError, /the deleted costs were \$0.00, \$16.00, \$70.00/)
      expect(costs(pasta)).to eq([[pasta_cook.id, 0, false], [second_cook.id, described_class::NOTHING, false]])
    end

    it 'does nothing, and says so, on a database with no meal on the BBQ day' do
      SettledWrites.with_repair_bypass { bbq.update_columns(date: described_class::BBQ - 7) }

      expect(migrate(:up)).to include('No meal on 2019-09-02: nothing to put back.')
      expect(fix_rows).to be_empty
    end

    def create_audit_of(bill)
      Audited::Audit.where(auditable_type: 'Bill', auditable_id: bill.id, action: 'create')
    end

    # More states it does not expect. Each stops the deploy and changes
    # nothing. Two dinner states are hard to make on settled rows, so for
    # those the two rows the lock reads are changed as they are read.
    {
      'there is no meal on the pasta day' => lambda {
        SettledWrites.with_repair_bypass { pasta.update_columns(date: described_class::PASTA + 7) }
      },
      'the BBQ dinner is not settled' => lambda {
        allow(migration).to receive(:lock_meals).and_wrap_original do |original|
          found_bbq, found_pasta = original.call
          [found_bbq.dup.tap { |row| row.reconciliation_id = nil }, found_pasta]
        end
      },
      'the two dinners are in different settlements' => lambda {
        allow(migration).to receive(:lock_meals).and_wrap_original do |original|
          found_bbq, found_pasta = original.call
          [found_bbq, found_pasta.dup.tap { |row| row.reconciliation_id = found_bbq.reconciliation_id.to_i + 1 }]
        end
      },
      'the BBQ dinner has a third cost' => lambda {
        SettledWrites.with_repair_bypass do
          Bill.insert!({ meal_id: bbq.id, resident_id: helper.id, community_id: community.id, amount: 0,
                         no_cost: false, created_at: Time.current, updated_at: Time.current })
        end
      },
      'the pasta dinner does not have the two costs it had' => lambda {
        SettledWrites.with_repair_bypass { Bill.where(meal: pasta, resident: second_cook).update_all(amount: 40) }
      },
      'only two deleted costs are found' => -> { create_audit_of(deleted.first).delete_all },
      'two deleted costs are of one cook' => lambda {
        create_audit_of(deleted.first)
          .update_all("audited_changes = jsonb_set(audited_changes, '{resident_id}', '#{helper.id}')")
      }
    }.each do |state, arrange|
      it "refuses and changes nothing when #{state}" do
        instance_exec(&arrange)
        before = Bill.order(:id).pluck(:id, :meal_id, :amount, :no_cost)

        expect { migrate(:up) }.to raise_error(RuntimeError, /Nothing was changed/)
        expect(Bill.order(:id).pluck(:id, :meal_id, :amount, :no_cost)).to eq(before)
        expect(fix_rows).to be_empty
      end
    end

    it 'takes back the correction and every cost change when a later step fails' do
      allow(migration).to receive(:touch_meals).and_raise(RuntimeError, 'a later step failed')

      expect { migrate(:up) }.to raise_error(RuntimeError, 'a later step failed')
      expect(SettlementCorrection.count).to eq(0)
      expect(bbq.bills.count).to eq(2)
      expect(costs(pasta)).to eq([[pasta_cook.id, 0, false], [second_cook.id, described_class::NOTHING, false]])
    end

    it 'refuses and changes nothing when the settlement already disagrees with its rows' do
      SettledWrites.with_repair_bypass { MealResident.where(meal: bbq).limit(1).update_all(multiplier: 1) }

      expect { migrate(:up) }.to raise_error(Settlement::EarlierDifference)
      expect(bbq.bills.count).to eq(2)
      expect(fix_rows).to be_empty
    end
  end

  # Three helpers handle a case the checks before them rule out in a real
  # run: own gets a cost only after check_costs found both, set_cost is
  # called only with amounts that change, and restore only with rows that
  # hold an amount. These examples show what each does in that case, on a
  # dinner that is not settled.
  describe 'the helpers, in cases a real run does not reach' do
    let(:open_meal) { create(:meal, community: community, date: described_class::PASTA + 30) }
    let(:open_bill) { create(:bill, meal: open_meal, resident: helper, community: community, amount: 0) }
    let(:cost_row) do
      described_class::CostRow.new(open_bill.id, helper.id, BigDecimal('0'), false, community.id, Time.current)
    end
    let(:stamp) { described_class::Stamp.new(Time.current.utc, SecureRandom.uuid) }

    it 'own finds nothing for no cost' do
      expect(migration.send(:own, [cost_row], nil)).to be_nil
    end

    it 'set_cost writes only the column that changed when the amount stays' do
      migration.send(:set_cost, cost_row, BigDecimal('0'), true, open_meal.id, stamp)

      expect(open_bill.reload).to have_attributes(amount: 0, no_cost: true)
      expect(fix_rows.sole.audited_changes).to eq('no_cost' => [false, true])
    end

    it 'restore puts back only No cost when the row holds no amount' do
      open_bill.update_columns(no_cost: true)

      migration.send(:restore, open_bill.id, { 'no_cost' => [false, true] }, Time.current.utc)

      expect(open_bill.reload).to have_attributes(amount: 0, no_cost: false)
    end
  end

  describe 'down' do
    it 'puts every cost back as it was, with its id, works the settlement out again, and removes its rows' do
      before = balances
      was = [costs(bbq), costs(pasta)]
      ids = [bbq.bills.pluck(:id).sort, pasta.bills.pluck(:id).sort]
      migrate(:up)

      migrate(:down)

      expect([costs(bbq), costs(pasta)]).to eq(was)
      expect([bbq.bills.pluck(:id).sort, pasta.bills.pluck(:id).sort]).to eq(ids)
      expect(balances).to eq(before)
      expect(SettlementCorrection.order(:id).last.reason).to start_with('Migration 20261013120100 was rolled back')
      expect(fix_rows).to be_empty
    end

    it 'does nothing, and says so, when up changed no cost' do
      expect(migrate(:down)).to include('This migration changed no cost: nothing to put back.')
      expect(bbq.bills.count).to eq(2)
    end

    it 'refuses when a cost it changed changed again since' do
      migrate(:up)
      SettledWrites.with_repair_bypass do
        Bill.where(meal: pasta, resident: pasta_cook).update_all(amount: 50, updated_at: 1.minute.from_now)
      end

      expect { migrate(:down) }.to raise_error(RuntimeError, /changed after migration 20261013120100/)
    end
  end

  it_behaves_like 'a data migration that tries a conflict again', described_class
end
