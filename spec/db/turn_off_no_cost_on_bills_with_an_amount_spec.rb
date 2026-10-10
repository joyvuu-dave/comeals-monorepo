# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('db/migrate/20261010130000_turn_off_no_cost_on_bills_with_an_amount.rb')

# The data migration that turns No cost off on every bill that has No cost
# and an amount. Before April 2026 the meal page let a cost be typed into
# a row marked No cost, and MealLedger leaves a no-cost bill out of the
# meal's cost, so those cooks were credited $0 for what they spent. The
# amount stays; only the flag changes, and the meal history says so. On a
# meal not settled yet, the amount counts at the next settlement. A
# settlement that already claimed such a bill is worked out again with the
# amount counted (Settlement#correct!), and the nightly check passes.
RSpec.describe TurnOffNoCostOnBillsWithAnAmount do
  let(:migration) { described_class.new }
  let(:check_name) { 'bills_no_cost_means_no_amount' }
  let(:connection) { ActiveRecord::Base.connection }

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
    Audited::Audit.where(auditable_type: 'Bill', comment: [described_class::COMMENT, described_class::SETTLED_COMMENT])
  end

  # nil when the CHECK is not there, else whether PostgreSQL has checked
  # the rows already in the table.
  def check_validated
    connection.select_value(<<~SQL.squish)
      SELECT convalidated FROM pg_constraint
      WHERE conname = '#{check_name}' AND conrelid = 'bills'::regclass
    SQL
  end

  context 'with bills of every kind' do
    let(:community) { create(:community) }
    let(:unit) { create(:unit, community: community) }
    let(:open_meal) { create(:meal, community: community, date: Date.new(2024, 5, 18)) }
    let(:other_open_meal) { create(:meal, community: community, date: Date.new(2025, 1, 8)) }
    let(:settled_meal) { create(:meal, community: community, date: Date.new(2023, 3, 5)) }
    let(:jane) { cook('Jane Smith') }
    let(:dee) { cook('Dee Park') }
    # Bills with No cost and an amount are written the way the app wrote
    # them before April 2026 (no_cost_bill_with_an_amount), which leaves
    # the CHECK bills_no_cost_means_no_amount NOT VALID, as production has
    # it when this migration runs. The settled one comes first: the
    # reconciliation factory settles every past meal it can, and the open
    # meals below must stay open. Its settlement left Eve's $40 out:
    # Gus is credited $12 and Ann charged $12. Counted, Eve is credited $40
    # and Ann charged $52.
    let!(:settled) do
      create(:meal_resident, meal: settled_meal, resident: cook('Ann Fox'), community: community)
      create(:bill, meal: settled_meal, resident: cook('Gus Hill'), community: community, amount: 12)
      bill = no_cost_bill_with_an_amount(meal: settled_meal, resident: cook('Eve Ray'), amount: '40')
      create(:reconciliation, community: community)
      raise 'setup failed: the meal was not settled' unless settled_meal.reload.reconciled?

      bill
    end
    let!(:fixed) { no_cost_bill_with_an_amount(meal: open_meal, resident: jane, amount: '86') }
    let!(:also_fixed) { no_cost_bill_with_an_amount(meal: other_open_meal, resident: dee, amount: '35.5') }
    let!(:normal) { create(:bill, meal: open_meal, resident: cook('Bob Lee'), community: community, amount: 12) }
    let!(:free) do
      create(:bill, meal: open_meal, resident: cook('Carl Wu'), community: community, amount: 0, no_cost: true)
    end

    def cook(name)
      create(:resident, community: community, unit: unit, name: name)
    end

    # What the settlement stored: its balances, and its line items.
    def settled_books
      reconciliation = settled_meal.reload.reconciliation
      [reconciliation.reconciliation_balances.order(:resident_id).pluck(:resident_id, :amount),
       MealCharge.for_reconciliation(reconciliation).pluck(:meal_id, :resident_id, :kind, :amount).sort]
    end

    describe 'up' do
      it 'turns No cost off on each bill with an amount, on open and settled meals, and keeps the amount' do
        migrate(:up)

        expect(fixed.reload).to have_attributes(no_cost: false, amount: BigDecimal('86'))
        expect(also_fixed.reload).to have_attributes(no_cost: false, amount: BigDecimal('35.5'))
        expect(settled.reload).to have_attributes(no_cost: false, amount: BigDecimal('40'))
      end

      it 'leaves a no-cost bill with $0 and a normal bill as they were' do
        before = [free, normal].map { |bill| bill.reload.attributes }

        migrate(:up)

        expect([free, normal].map { |bill| bill.reload.attributes }).to eq(before)
        expect(fix_rows.where(auditable_id: [free.id, normal.id])).to be_empty
      end

      it 'moves updated_at on each fixed bill and its meal, so the calendar version moves, and on nothing else' do
        untouched = [free, normal].map { |row| row.reload.updated_at }
        touched = [fixed, also_fixed, settled, open_meal, other_open_meal, settled_meal]
        before = touched.map { |row| row.reload.updated_at }

        migrate(:up)

        expect(touched.map { |row| row.reload.updated_at }).to all(be > before.max)
        expect([free, normal].map { |row| row.reload.updated_at }).to eq(untouched)
      end

      it 'counts the cost in a meal not settled yet' do
        create(:meal_resident, meal: open_meal, resident: cook('Ivy Tan'), community: community)

        expect { migrate(:up) }.to change { MealCostSummary.for(open_meal.reload).total_cost }
          .from(BigDecimal('12')).to(BigDecimal('98'))
      end

      # The owner decided on 2026-10-10 that every settled number must be
      # right too. The settlement is worked out again with Eve's $40.
      it 'works out again the settlement of a settled meal, counting the amount, and the nightly check passes' do
        migrate(:up)

        reconciliation = settled_meal.reload.reconciliation
        expect(reconciliation.reconciliation_balances.joins(:resident).pluck('residents.name', :amount).sort)
          .to eq([['Ann Fox', BigDecimal('-52')], ['Eve Ray', BigDecimal('40')], ['Gus Hill', BigDecimal('12')]])
        expect(LedgerVerification.call).to be_passed
      end

      it 'keeps the settlement row and its meals' do
        reconciliation = settled_meal.reload.reconciliation
        before = reconciliation.attributes
        meals = reconciliation.meals.order(:id).pluck(:id)

        migrate(:up)

        expect(reconciliation.reload.attributes).to eq(before)
        expect(reconciliation.meals.order(:id).pluck(:id)).to eq(meals)
      end

      it 'records the correction with its reason, and each balance that changed, before and after' do
        migrate(:up)

        correction = SettlementCorrection.sole
        expect(correction).to have_attributes(
          reconciliation_id: settled_meal.reload.reconciliation_id,
          reason: '1 cost on these meals was marked No cost by mistake, so its cook was credited $0 for it. ' \
                  'These numbers now count that cost.'
        )
        expect(correction.lines.joins(:resident).pluck('residents.name', :old_amount, :new_amount).sort)
          .to eq([['Ann Fox', BigDecimal('-12'), BigDecimal('-52')], ['Eve Ray', BigDecimal('0'), BigDecimal('40')]])
      end

      it 'keeps the line items the settlement had before, in the correction' do
        old = MealCharge.for_reconciliation(settled_meal.reload.reconciliation)
                        .pluck(:id, :meal_id, :resident_id, :kind, :amount).sort

        migrate(:up)

        expect(SettlementCorrection.sole.charges.pluck(:meal_charge_id, :meal_id, :resident_id, :kind, :amount).sort)
          .to eq(old)
      end

      it 'works out nothing again when no fixed bill is on a settled meal' do
        SettledWrites.with_repair_bypass { settled.update_columns(amount: 0) }

        migrate(:up)

        expect(SettlementCorrection.count).to eq(0)
      end

      # Jane's bill was fixed while its meal was open, so the settlement
      # that comes after counts her $86, and the check reads her bill as
      # it is.
      it 'counts the amount at the next settlement of a meal it fixed while open' do
        create(:meal_resident, meal: open_meal, resident: cook('Ivy Tan'), community: community)
        migrate(:up)

        create(:reconciliation, community: community)

        expect(open_meal.reload).to be_reconciled
        jane_balance = open_meal.reconciliation.reconciliation_balances.find_by(resident: jane).amount
        expect(jane_balance).to eq(BigDecimal('86'))
        expect(LedgerVerification.call).to be_passed
      end

      it 'writes one audit row per fixed bill, as the next version of that bill, linked to its meal' do
        versions = [fixed, also_fixed, settled].map { |bill| bill.audits.maximum(:version) }

        migrate(:up)

        rows = fix_rows.order(:auditable_id).to_a
        expect(rows.map { |row| [row.auditable_id, row.version, row.associated_type, row.associated_id] })
          .to eq([[settled.id, versions[2] + 1, 'Meal', settled_meal.id],
                  [fixed.id, versions[0] + 1, 'Meal', open_meal.id],
                  [also_fixed.id, versions[1] + 1, 'Meal', other_open_meal.id]])
        expect(rows).to all(have_attributes(action: 'update', audited_changes: { 'no_cost' => [true, false] },
                                            user_id: nil, user_type: nil, username: nil))
        expect(rows.map(&:request_uuid).uniq.size).to eq(1)
      end

      # If the deploy is rolled back (#133), the release before this one
      # runs on this database, and its meal history names the maker of a
      # row with ResidentNameShortener.short(audit.user&.name). With a
      # username and no person, audited's `user` is that username, a
      # String, and `name` raised: the history of these meals answered 500.
      it 'writes rows the meal history of the release before this one can read' do
        migrate(:up)

        expect(fix_rows.count).to eq(3)
        expect(fix_rows.map { |row| ResidentNameShortener.short(row.user&.name) }).to all(eq(''))
      end

      # The comment is how down knows the meal was already settled.
      it 'marks the row of a bill whose meal was already settled' do
        migrate(:up)

        expect(fix_rows.order(:auditable_id).pluck(:auditable_id, :comment))
          .to eq([[settled.id, described_class::SETTLED_COMMENT],
                  [fixed.id, described_class::COMMENT],
                  [also_fixed.id, described_class::COMMENT]])
      end

      it 'shows the fix in the meal history, by who did it and in plain words' do
        migrate(:up)

        open_line = AuditSerializer.new(open_meal.reload.total_audits).to_h.first
        settled_line = AuditSerializer.new(settled_meal.reload.total_audits).to_h.first
        expect(open_line).to include(
          user_name: 'Automatic fix',
          description: "Bill for Jane no longer marked as no cost, so the $86.00 now counts in the meal's cost"
        )
        expect(settled_line).to include(
          user_name: 'Automatic fix',
          description: "Bill for Eve no longer marked as no cost, so the $40.00 now counts in the meal's cost"
        )
      end

      it 'prints each fixed bill and the totals, for the release log' do
        out = migrate(:up)

        expect(out).to include('2024-05-18  Jane Smith  $86.00')
        expect(out).to include('2025-01-08  Dee Park  $35.50')
        expect(out).to include('2023-03-05  Eve Ray  $40.00  (settled)')
        expect(out).to include('Turned No cost off on 2 bill(s) on 2 meal(s) not settled yet, $121.50 in all.')
        expect(out).to include('Turned No cost off on 1 bill(s) on 1 settled meal(s), $40.00 in all.')
        expect(out).to include("Worked out settlement #{settled_meal.reload.reconciliation_id} again for its " \
                               '1 bill(s): 2 balance(s) changed. Its admin page lists them.')
      end

      it 'takes the meal locks before it writes a bill' do
        statements = []
        callback = ->(*, payload) { statements << payload[:sql] }
        ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') { migrate(:up) }

        lock = statements.index { |sql| sql.include?('FROM meals') && sql.include?('FOR UPDATE') }
        write = statements.index { |sql| sql.start_with?('UPDATE bills') }
        expect(lock).not_to be_nil
        expect(write).not_to be_nil
        expect(lock).to be < write
      end

      # The bypass lets a write through every guard of a settled meal, so
      # it is on for the statements that need it and off after: the write
      # to the settled bills, then the two deletes of the settlement's old
      # numbers (Settlement#correct!).
      it 'turns the settled-write bypass on only for the settled bills and the old numbers' do
        statements = []
        callback = ->(*, payload) { statements << payload[:sql] }
        ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') { migrate(:up) }

        on = statements.index("SET LOCAL comeals.allow_settled_writes = 'on'")
        expect(on).not_to be_nil
        expect(statements[on + 1]).to start_with('UPDATE bills').and include(settled.id.to_s)
        expect(statements[on + 2]).to eq("SET LOCAL comeals.allow_settled_writes = 'off'")
        again = statements.index { |sql| sql.include?("set_config('comeals.allow_settled_writes', 'on', true)") }
        back = statements.index { |sql| sql.include?("set_config('comeals.allow_settled_writes', 'off', true)") }
        writes = statements[(again + 1)...back].grep_v(/\A\s*SELECT/)
        expect(writes).to match([start_with('DELETE FROM "meal_charges"'),
                                 start_with('DELETE FROM "reconciliation_balances"')])
        expect(statements.count { |sql| sql.include?("'comeals.allow_settled_writes', 'on'") }).to eq(1)
        expect(connection.select_value("SELECT current_setting('comeals.allow_settled_writes', true)")).to eq('off')
      end

      it 'says so and writes nothing when no bill needs it' do
        SettledWrites.with_repair_bypass { settled.update_columns(amount: 0) }
        [fixed, also_fixed].each { |bill| bill.update_columns(amount: 0) }

        out = migrate(:up)

        expect(out).to include('No bill has both No cost and an amount.')
        expect(fix_rows).to be_empty
      end
    end

    describe 'down' do
      it 'puts back exactly the bills it changed, removes its rows, and leaves the CHECK as it found it' do
        others = [free, normal].map { |bill| bill.reload.attributes }
        migrate(:up)

        migrate(:down)

        expect(fixed.reload).to have_attributes(no_cost: true, amount: BigDecimal('86'))
        expect(also_fixed.reload).to have_attributes(no_cost: true, amount: BigDecimal('35.5'))
        expect(settled.reload).to have_attributes(no_cost: true, amount: BigDecimal('40'))
        expect([free, normal].map { |bill| bill.reload.attributes }).to eq(others)
        expect(fix_rows).to be_empty
        expect(check_validated).to be(false)
      end

      # A correction is a record of what happened, so down adds one that
      # says why, rather than deleting up's. The numbers are the old ones
      # again, and so are the line items.
      it 'works the settlement out again from the bills put back, and records why' do
        books = settled_books
        migrate(:up)

        out = migrate(:down)

        expect(settled_books).to eq(books)
        expect(LedgerVerification.call).to be_passed
        expect(SettlementCorrection.order(:id).pluck(:reason).last).to eq(
          'Migration 20261010130000 was rolled back, so 1 cost on these meals is marked No cost again. ' \
          'These numbers leave it out again.'
        )
        expect(SettlementCorrection.count).to eq(2)
        expect(out).to include("Worked out settlement #{settled_meal.reload.reconciliation_id} again for its " \
                               '1 bill(s): 2 balance(s) changed.')
      end

      # The bill is no longer as the fix left it, so putting back No cost
      # would undo a person's later change. Its row stays, since the fix
      # still stands in its history.
      it 'leaves a bill that someone changed after the fix, and says so' do
        migrate(:up)
        also_fixed.reload.update!(amount: BigDecimal('30'))

        out = migrate(:down)

        expect(also_fixed.reload).to have_attributes(no_cost: false, amount: BigDecimal('30'))
        expect([fixed, settled].map { |bill| bill.reload.no_cost }).to eq([true, true])
        expect(fix_rows.pluck(:auditable_id)).to eq([also_fixed.id])
        expect(out).to include("Left as it is, because it changed after the fix: bill #{also_fixed.id} (2025-01-08)")
      end

      # The settlement after the fix counted Jane's $86. Putting No cost
      # back would make it disagree with its bills.
      it 'refuses when a bill it fixed on an open meal is on a meal settled since, naming it, and changes nothing' do
        create(:meal_resident, meal: open_meal, resident: cook('Ivy Tan'), community: community)
        migrate(:up)
        create(:reconciliation, community: community)

        expect { migrate(:down) }.to raise_error(
          RuntimeError,
          "1 bill(s) this migration fixed are on a meal settled since: bill #{fixed.id} (2024-05-18). " \
          'A settled meal cannot change, so this migration cannot be undone.'
        )
        expect([fixed, settled].map { |bill| bill.reload.no_cost }).to eq([false, false])
        expect(fix_rows.count).to eq(3)
        expect(SettlementCorrection.count).to eq(1)
      end

      it 'leaves a bill deleted after the fix, and keeps its row' do
        migrate(:up)
        also_fixed.reload.destroy!

        out = migrate(:down)

        expect(fixed.reload.no_cost).to be(true)
        expect(fix_rows.pluck(:auditable_id)).to eq([also_fixed.id])
        expect(out).to include("Left as it is, because it changed after the fix: bill #{also_fixed.id} (2025-01-08)")
      end

      # A rollback runs migration 20261010130200's down first, which makes
      # the CHECK NOT VALID again. Run alone, this down would leave the
      # CHECK NOT VALID while that migration still counts as run.
      it 'refuses while the CHECK is validated, and changes nothing' do
        migrate(:up)
        connection.validate_check_constraint(:bills, name: check_name)

        expect { migrate(:down) }.to raise_error(RuntimeError, /\ARoll back migration 20261010130200 first\./)
        expect([fixed, also_fixed, settled].map { |bill| bill.reload.no_cost }).to eq([false, false, false])
        expect(fix_rows.count).to eq(3)
        expect(check_validated).to be(true)
      end
    end
  end

  # Two fixed bills on one settlement's meals: the settlement is worked out
  # once, and its correction says 2.
  context 'with two fixed bills on one settled meal' do
    it 'works the settlement out once, for both' do
      community = create(:community)
      unit = create(:unit, community: community)
      meal = create(:meal, community: community, date: Date.new(2023, 3, 5))
      person = ->(name) { create(:resident, community: community, unit: unit, name: name) }
      create(:meal_resident, meal: meal, resident: person.call('Ann Fox'), community: community)
      no_cost_bill_with_an_amount(meal: meal, resident: person.call('Eve Ray'), amount: '10')
      no_cost_bill_with_an_amount(meal: meal, resident: person.call('Hal Ito'), amount: '8')
      create(:reconciliation, community: community)

      out = migrate(:up)

      expect(SettlementCorrection.sole.reason).to start_with('2 costs on these meals were marked No cost')
      expect(out).to include('again for its 2 bill(s): 3 balance(s) changed.')
      expect(LedgerVerification.call).to be_passed
    end
  end

  # Settlement#correct! works a settlement out again from all of its rows,
  # not only from the bills this migration fixes. If a settlement already
  # disagreed with its rows before the fix (a past repair that changed a
  # row and never worked the settlement out again), the correction would
  # fold that in under this migration's reason, and the nightly check
  # would stop reporting it. So the migration refuses, and changes
  # nothing.
  #
  # Meal A: Casey's $30 receipt, Dana eats. Meal B: Eve's $40 receipt,
  # marked No cost, Finn eats. One settlement claims both. Then a past
  # repair changes Casey's receipt to $36 and never works the settlement
  # out again. (Written by a review of 8a994760.)
  context 'when a settlement already disagreed with its rows' do
    let(:community) { create(:community) }
    let(:unit) { create(:unit, community: community) }
    let(:casey) { person('Casey Cook') }
    let(:dana) { person('Dana Diner') }
    let(:eve) { person('Eve Ray') }
    let(:finn) { person('Finn Ate') }
    let!(:reconciliation) do
      meal_a = create(:meal, community: community, date: Date.new(2023, 3, 1))
      receipt = create(:bill, meal: meal_a, resident: casey, community: community, amount: 30)
      create(:meal_resident, meal: meal_a, resident: dana, community: community)
      meal_b = create(:meal, community: community, date: Date.new(2023, 3, 5))
      no_cost_bill_with_an_amount(meal: meal_b, resident: eve, amount: '40')
      create(:meal_resident, meal: meal_b, resident: finn, community: community)
      settled = create(:reconciliation, community: community)
      SettledWrites.with_repair_bypass { receipt.update_columns(amount: BigDecimal('36')) }
      settled
    end

    def person(name)
      create(:resident, community: community, unit: unit, name: name)
    end

    it 'starts from a settlement the nightly check already reports' do
      expect { LedgerVerification.call }.to raise_error(LedgerVerification::MismatchError)
    end

    it 'refuses to work out again a settlement that did not match its rows before the fix' do
      expect { migrate(:up) }.to raise_error(RuntimeError, /settlement #{reconciliation.id}\b/)
      expect(Bill.where(no_cost: true).where('amount > 0').count).to eq(1)
    end

    # The harm if it did not refuse: Casey and Dana, who have nothing to
    # do with Eve's No cost bill, would get correction lines under the
    # reason "1 cost on these meals was marked No cost by mistake", and
    # the nightly check would go quiet about the earlier change.
    it 'does not blame the fix for a change it did not make, or hide that change from the nightly check' do
      begin
        migrate(:up)
      rescue RuntimeError
        nil
      end

      names = SettlementCorrectionLine.joins(:resident).pluck('residents.name')
      expect(names).not_to include('Casey Cook', 'Dana Diner')
      expect { LedgerVerification.call }.to raise_error(LedgerVerification::MismatchError)
    end
  end

  # The whole app runs at SERIALIZABLE, so a bills save or a settlement
  # committing while the migration runs can make PostgreSQL refuse it. The
  # migration runs its own transaction again, as RetryOnConflict does. Only
  # outside a test transaction can a transaction be run again, so this group
  # has none, and makes no rows: the refusals are made up.
  context 'when PostgreSQL refuses it for a conflict' do
    include_context 'with no test transaction'

    # The first `refusals` reads of the meals raise the error, as PostgreSQL
    # would; each later one runs.
    def refuse_first(refusals, error)
      calls = 0
      allow(migration.connection).to receive(:select_values).and_wrap_original do |original, *args|
        calls += 1
        raise error, 'could not serialize access' if calls <= refusals

        original.call(*args)
      end
    end

    before { allow(migration).to receive(:sleep) }

    it 'runs again after a serialization failure, and says so' do
      refuse_first(2, ActiveRecord::SerializationFailure)

      out = migrate(:up)

      expect(out).to include('Trying again (2 of 5)', 'Trying again (3 of 5)')
      expect(out).to include('No bill has both No cost and an amount.')
    end

    it 'runs again after a deadlock' do
      refuse_first(1, ActiveRecord::Deadlocked)

      expect(migrate(:up)).to include('Trying again (2 of 5)', 'No bill has both No cost and an amount.')
    end

    it 'gives up after five tries, so the release fails' do
      refuse_first(5, ActiveRecord::SerializationFailure)

      expect { migrate(:up) }.to raise_error(ActiveRecord::SerializationFailure)
    end
  end
end
