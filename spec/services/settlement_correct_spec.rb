# frozen_string_literal: true

require 'rails_helper'

# Settlement#correct! works a settled period out again from its meals'
# rows as they are now, and records what changed. It is for a settlement
# whose rows were wrong, when the owner decides the settlement must show
# the right numbers (migration 20261010130000 is the first). The caller
# fixes the rows in its block; before the block runs, correct! refuses a
# settlement that already disagrees with its rows.
#
# Every example settles first, then fixes a row the way a repair does,
# with the bypass on.
RSpec.describe Settlement, '#correct!' do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community, name: 'Elm') }
  let(:reason) { '1 cost on these meals was entered as $0 by mistake.' }

  def person(name)
    create(:resident, community: community, unit: unit, name: name)
  end

  # A meal on `date` with one bill and the eaters given. Every eater pays
  # the adult price, so a meal's cost is split evenly.
  def meal(date, cook:, amount:, eaters:)
    meal = create(:meal, community: community, date: date)
    bill = create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal(amount))
    eaters.each { |eater| create(:meal_resident, meal: meal, resident: eater, community: community) }
    [meal, bill]
  end

  def balances(reconciliation)
    reconciliation.reconciliation_balances.pluck(:resident_id, :amount).to_h
  end

  def lines(correction)
    correction.lines.order(:resident_id).pluck(:resident_id, :old_amount, :new_amount)
  end

  def bypass_setting
    ActiveRecord::Base.connection.select_value("SELECT current_setting('comeals.allow_settled_writes', true)")
  end

  # A repair's change to a row of a settled meal.
  def change_amount(bill, amount)
    SettledWrites.with_repair_bypass { bill.update_columns(amount: BigDecimal(amount)) }
  end

  def correct(reconciliation, amount: nil, bill: nil, **)
    described_class.new(reconciliation).correct!(reason: reason, **) do
      change_amount(bill, amount) if bill
    end
  end

  context 'with a cost that was too low when the period was settled' do
    let(:cook) { person('Casey Cook') }
    let(:dana) { person('Dana Diner') }
    let(:eli) { person('Eli Eater') }
    # Casey's second receipt was $10, and the settlement read $0.
    let!(:second) { meal(Date.new(2025, 3, 2), cook: cook, amount: '0', eaters: [dana]).last }
    let!(:reconciliation) do
      meal(Date.new(2025, 3, 1), cook: cook, amount: '30', eaters: [dana, eli])
      settle_as_before_rule_3!(cutoff: Date.new(2025, 3, 31))
    end

    def fix(**)
      correct(reconciliation, bill: second, amount: '10', **)
    end

    it 'works the balances out again from the rows as they are after the fix' do
      fix

      expect(balances(reconciliation)).to eq(cook.id => BigDecimal('40'), dana.id => BigDecimal('-25'),
                                             eli.id => BigDecimal('-15'))
    end

    it 'keeps the same settlement row, the same meals and the same dates' do
      before = reconciliation.reload.attributes
      meals = reconciliation.meals.order(:id).pluck(:id)

      fix

      expect(reconciliation.reload.attributes).to eq(before)
      expect(reconciliation.meals.order(:id).pluck(:id)).to eq(meals)
    end

    it 'records the reason, and each person whose balance changed, before and after' do
      correction = fix

      expect(correction).to have_attributes(reconciliation_id: reconciliation.id, reason: reason,
                                            include_earlier_differences: false, earlier_differences: [])
      expect(lines(correction))
        .to eq([[cook.id, BigDecimal('30'), BigDecimal('40')], [dana.id, BigDecimal('-15'), BigDecimal('-25')]])
      expect(reconciliation.settlement_corrections).to eq([correction])
    end

    # The record keeps what the settlement said line by line too, so a
    # second correction of the same settlement loses nothing.
    it 'keeps a copy of every line item it replaced, column for column' do
      old = MealCharge.for_reconciliation(reconciliation).order(:id).map do |charge|
        [charge.id, charge.meal_id, charge.resident_id, charge.kind, charge.amount, charge.multiplier,
         charge.unit_cost, charge.bill_amount, charge.created_at]
      end

      correction = fix

      expect(correction.charges.order(:meal_charge_id).map do |kept|
        [kept.meal_charge_id, kept.meal_id, kept.resident_id, kept.kind, kept.amount, kept.multiplier,
         kept.unit_cost, kept.bill_amount, kept.charged_at]
      end).to eq(old)
      expect(MealCharge.where(id: old.map(&:first))).to be_empty
    end

    it 'writes line items that add up to the new balances, so the nightly check passes' do
      fix

      expect(MealCharge.for_reconciliation(reconciliation).group(:resident_id).sum(:amount))
        .to eq(cook.id => BigDecimal('40'), dana.id => BigDecimal('-25'), eli.id => BigDecimal('-15'))
      expect(LedgerVerification.call).to be_passed
    end

    # Every settlement before 2026-08-02 has balances and no line items.
    # The correction writes them, so the second check covers it too.
    it 'writes line items for a settlement that had none' do
      SettledWrites.with_repair_bypass { MealCharge.for_reconciliation(reconciliation).delete_all }

      correction = fix

      expect(correction.charges).to be_empty
      expect(MealCharge.for_reconciliation(reconciliation).count).to eq(5)
      expect(LedgerVerification.call).to be_passed
    end

    # Two corrections of one settlement run one after the other: the
    # settlement row is locked first, before anything is read or written.
    it 'locks the settlement row before it reads or writes anything' do
      statements = []
      record = ->(*, payload) { statements << payload[:sql] }

      ActiveSupport::Notifications.subscribed(record, 'sql.active_record') { fix }

      lock = statements.index { |sql| sql.match?(/FROM "reconciliations" WHERE .* FOR UPDATE\z/) }
      expect(lock).not_to be_nil
      expect(statements[0...lock].grep(/\A\s*(SELECT|INSERT|UPDATE|DELETE)/)).to be_empty
    end

    it 'turns the bypass off again after its deletes' do
      fix

      expect(bypass_setting).to eq('')
      expect { ReconciliationBalance.where(reconciliation_id: reconciliation.id).delete_all }
        .to raise_error(ActiveRecord::StatementInvalid, /reconciliation_balances refused/)
    end

    # A caller that had the bypass on for its own repair keeps it on.
    it 'puts the bypass back to what it was' do
      SettledWrites.with_repair_bypass do
        described_class.new(reconciliation).correct!(reason: reason) do
          second.update_columns(amount: BigDecimal('10'))
        end

        expect(bypass_setting).to eq('on')
      end
    end

    it 'records a second correction of the same settlement after the first' do
      first_correction = fix

      second_correction = correct(reconciliation, bill: second, amount: '12')

      expect(reconciliation.settlement_corrections.reload).to eq([first_correction, second_correction])
      expect(lines(second_correction))
        .to eq([[cook.id, BigDecimal('40'), BigDecimal('42')], [dana.id, BigDecimal('-25'), BigDecimal('-27')]])
      expect(second_correction.charges.count).to eq(5)
    end

    it 'puts nothing in place of the old numbers if it fails, the fix included, and records nothing' do
      books = balances(reconciliation)
      allow(SettlementCorrectionLine).to receive(:insert_all!).and_raise(ActiveRecord::StatementInvalid, 'boom')

      expect { fix }.to raise_error(ActiveRecord::StatementInvalid, 'boom')
      expect(balances(reconciliation)).to eq(books)
      expect(second.reload.amount).to eq(BigDecimal('0'))
      expect(SettlementCorrection.count).to eq(0)
    end

    # A correction works the settlement out again from all of its rows. A
    # difference that was there before the fix would be folded in under
    # the caller's reason, and the nightly check would stop reporting it.
    describe 'a settlement that already disagreed with its rows' do
      before { change_amount(second, '5') }

      it 'refuses before the fix runs, names the settlement, and writes nothing' do
        books = balances(reconciliation)

        expect { fix }.to raise_error(Settlement::EarlierDifference,
                                      /\ARefused: settlement #{reconciliation.id} already disagrees.*recompute/)
        expect(second.reload.amount).to eq(BigDecimal('5'))
        expect(balances(reconciliation)).to eq(books)
        expect(SettlementCorrection.count).to eq(0)
      end

      it 'refuses a call with no block, whose rows were changed before it' do
        expect { described_class.new(reconciliation).correct!(reason: reason) }
          .to raise_error(Settlement::EarlierDifference)
      end

      # A caller that means to fold an earlier difference in says so.
      it 'folds it in when the caller says so' do
        correction = fix(include_earlier_differences: true)

        expect(lines(correction))
          .to eq([[cook.id, BigDecimal('30'), BigDecimal('40')], [dana.id, BigDecimal('-15'), BigDecimal('-25')]])
        expect(LedgerVerification.call).to be_passed
      end

      # So a correction that folded something in never looks like a clean
      # one: the record says the caller allowed it, and keeps what the
      # nightly check found just before, in the check's own shape.
      it 'records that it folded the earlier difference in, and what the check found' do
        correction = fix(include_earlier_differences: true)

        expect(correction.include_earlier_differences).to be(true)
        differences = [{ 'resident_id' => cook.id, 'stored' => '30.0', 'source' => '35.0' },
                       { 'resident_id' => dana.id, 'stored' => '-15.0', 'source' => '-20.0' }]
        # The dinner check sees the same change, on the dinner whose
        # receipt changed: its rows no longer add up to its lines.
        meal = second.meal
        dinner = [{ 'meal_id' => meal.id, 'meal_date' => meal.date.to_s, 'resident_id' => cook.id,
                    'stored' => '0.0', 'source' => '5.0' },
                  { 'meal_id' => meal.id, 'meal_date' => meal.date.to_s, 'resident_id' => dana.id,
                    'stored' => '0.0', 'source' => '-5.0' }]
        expect(correction.reload.earlier_differences).to eq(
          [{ 'reconciliation_id' => reconciliation.id, 'date' => reconciliation.date.to_s, 'check' => 'recompute',
             'differences' => differences },
           { 'reconciliation_id' => reconciliation.id, 'date' => reconciliation.date.to_s, 'check' => 'dinners',
             'differences' => dinner }]
        )
      end
    end

    it 'records that it was allowed to fold in, when the check found nothing' do
      correction = fix(include_earlier_differences: true)

      expect(correction).to have_attributes(include_earlier_differences: true, earlier_differences: [])
    end

    # Rails commits a transaction block that is left without an error, so
    # a fix block left by return, break or throw would keep the fix to the
    # settled rows with no correction and no new numbers. correct! raises
    # instead, and nothing stays. (Written by a review of f49d7fb0.)
    describe 'a fix block that leaves early' do
      # A caller written as a method, the way a migration or a rake task
      # would be: it fixes the receipt, then stops on a condition.
      def fix_then_return
        described_class.new(reconciliation).correct!(reason: reason) do
          change_amount(second, '10')
          return :stopped
        end
      end

      def fix_then_break
        described_class.new(reconciliation).correct!(reason: reason) do
          change_amount(second, '10')
          break
        end
      end

      def fix_then_throw
        catch(:stop) do
          described_class.new(reconciliation).correct!(reason: reason) do
            change_amount(second, '10')
            throw :stop
          end
        end
      end

      # Either the fix and the correction both stay, or neither does.
      def expect_nothing_kept
        expect(second.reload.amount).to eq(BigDecimal('0'))
        expect(SettlementCorrection.exists?(reconciliation_id: reconciliation.id)).to be(false)
        expect { LedgerVerification.call }.not_to raise_error
      end

      it 'refuses a block left by return, and keeps nothing' do
        expect { fix_then_return }.to raise_error(Settlement::FixLeftEarly, /left by return, break or throw/)
        expect_nothing_kept
      end

      it 'refuses a block left by break, and keeps nothing' do
        expect { fix_then_break }.to raise_error(Settlement::FixLeftEarly)
        expect_nothing_kept
      end

      it 'refuses a block left by throw, and keeps nothing' do
        expect { fix_then_throw }.to raise_error(Settlement::FixLeftEarly)
        expect_nothing_kept
      end

      # An error from the block is the caller's own, and goes on as it is.
      it 'passes an error from the block on unchanged, and keeps nothing' do
        expect do
          described_class.new(reconciliation).correct!(reason: reason) do
            change_amount(second, '10')
            raise ArgumentError, 'the fix found something wrong'
          end
        end.to raise_error(ArgumentError, 'the fix found something wrong')
        expect_nothing_kept
      end
    end

    # Line items that no longer add up to the balances are an earlier
    # difference too: the nightly check's second half reports them.
    it 'refuses a settlement whose line items no longer add up to its balances' do
      SettledWrites.with_repair_bypass do
        MealCharge.where(resident: dana).where('amount < 0').update_all('amount = amount + 0.01')
        MealCharge.where(resident: eli).update_all('amount = amount - 0.01')
      end

      expect { fix }.to raise_error(Settlement::EarlierDifference, /line_items/)
    end
  end

  # Nothing changed, so there is no line, but the record still says the
  # settlement was worked out again, and why.
  it 'records a correction with no lines when no balance changed' do
    cook = person('Casey Cook')
    meal(Date.new(2025, 3, 1), cook: cook, amount: '30', eaters: [person('Dana Diner')])
    reconciliation = settle!(cutoff: Date.new(2025, 3, 31))
    before = balances(reconciliation)

    correction = correct(reconciliation)

    expect(balances(reconciliation)).to eq(before)
    expect(correction.lines).to be_empty
  end

  # A balance that the fix brings to exactly zero has no row afterwards,
  # and its line says zero after.
  it 'records a balance that went to zero' do
    cook = person('Casey Cook')
    dana = person('Dana Diner')
    _, bill = meal(Date.new(2025, 3, 1), cook: cook, amount: '10', eaters: [dana])
    reconciliation = settle!(cutoff: Date.new(2025, 3, 31))

    correction = correct(reconciliation, bill: bill, amount: '0')

    expect(balances(reconciliation)).to eq({})
    expect(lines(correction))
      .to eq([[cook.id, BigDecimal('10'), BigDecimal('0')], [dana.id, BigDecimal('-10'), BigDecimal('0')]])
  end

  # ADR 0011 rules 6 and 8: once a line is marked Paid or Let go, people
  # have paid from the settlement, and its numbers stay what they were.
  it 'refuses a settlement with a marked line, before the fix runs, and writes nothing' do
    cook = person('Casey Cook')
    _, bill = meal(Date.new(2025, 3, 1), cook: cook, amount: '0', eaters: [person('Dana Diner'), cook])
    meal(Date.new(2025, 3, 2), cook: cook, amount: '9', eaters: [person('Eli Eater')])
    reconciliation = settle_as_before_rule_3!(cutoff: Date.new(2025, 3, 31))
    line = reconciliation.reconciliation_balances.first
    SettlementLineMarking.mark!(line, status: 'paid', note: nil, by: create(:admin_user, community: community),
                                      seen: nil)
    fixed = false

    expect do
      described_class.new(reconciliation).correct!(reason: reason) { fixed = true }
    end.to raise_error(Settlement::Marked, /has lines marked Paid or Let go/)
    expect(fixed).to be(false)
    expect(SettlementCorrection.count).to eq(0)
    expect(bill.reload.amount).to eq(0)
  end

  # ADR 0011 rule 7: the units on a settlement are the ones of its day.
  # Working it out again keeps each person's saved unit and lived-here,
  # whatever they are now. Someone with no line before (Casey, whose
  # receipt read $0) gets theirs as they are now: nothing else says it.
  it 'keeps the unit each person settled in, and gives someone new to it their unit now' do
    oak = create(:unit, community: community, name: 'Oak')
    cook = person('Casey Cook')
    dana = person('Dana Diner')
    eli = person('Eli Eater')
    _, bill = meal(Date.new(2025, 3, 1), cook: cook, amount: '0', eaters: [dana, eli])
    meal(Date.new(2025, 3, 2), cook: eli, amount: '8', eaters: [dana])
    reconciliation = settle_as_before_rule_3!(cutoff: Date.new(2025, 3, 31))
    expect(reconciliation.saved_units).to eq(dana.id => [unit.id, true], eli.id => [unit.id, true])
    dana.update!(unit: oak, active: false)
    cook.update!(unit: oak)

    correct(reconciliation, bill: bill, amount: '12')

    expect(balances(reconciliation).keys).to contain_exactly(cook.id, dana.id, eli.id)
    expect(reconciliation.saved_units)
      .to eq(dana.id => [unit.id, true], eli.id => [unit.id, true], cook.id => [oak.id, true])
  end

  # A cook whose receipt was read as $0 had no balance before, and is
  # credited after.
  it 'records a cook credited for the first time' do
    cook = person('Casey Cook')
    dana = person('Dana Diner')
    _, bill = meal(Date.new(2025, 3, 1), cook: cook, amount: '0', eaters: [dana])
    reconciliation = settle_as_before_rule_3!(cutoff: Date.new(2025, 3, 31))
    expect(balances(reconciliation)).to eq({})

    correction = correct(reconciliation, bill: bill, amount: '12')

    expect(lines(correction))
      .to eq([[cook.id, BigDecimal('0'), BigDecimal('12')], [dana.id, BigDecimal('0'), BigDecimal('-12')]])
  end

  # The cents are shared out across the whole settlement
  # (allocate_to_cents), so fixing one meal can move a leftover cent to
  # or from a person who did not eat there. That cent is recorded too.
  #
  # Before: the first meal's $1.00 across three leaves 1 cent over, and
  # Uma, whose share lost the most when cut to cents, pays it: $0.34.
  # After the second meal's $2.00 counts, 3 cents are left over, and the
  # second meal's three eaters lost more than Uma did, so they pay them.
  # Uma pays $0.33, though she did not eat at the second meal.
  it 'records a person who moved only by a leftover cent, with every other change' do
    uma = person('Uma One')
    second_eaters = [person('Xia Four'), person('Yan Five'), person('Zed Six')]
    meal(Date.new(2025, 3, 1), cook: person('Casey Cook'), amount: '1',
                               eaters: [uma, person('Vic Two'), person('Wes Three')])
    cleo = person('Cleo Cook')
    _, bill = meal(Date.new(2025, 3, 2), cook: cleo, amount: '0', eaters: second_eaters)
    reconciliation = settle_as_before_rule_3!(cutoff: Date.new(2025, 3, 31))
    expect(balances(reconciliation).fetch(uma.id)).to eq(BigDecimal('-0.34'))

    correction = correct(reconciliation, bill: bill, amount: '2')

    xia, yan, zed = second_eaters
    expect(lines(correction)).to eq([
      [uma.id, BigDecimal('-0.34'), BigDecimal('-0.33')],
      [xia.id, BigDecimal('0'), BigDecimal('-0.67')],
      [yan.id, BigDecimal('0'), BigDecimal('-0.67')],
      [zed.id, BigDecimal('0'), BigDecimal('-0.67')],
      [cleo.id, BigDecimal('0'), BigDecimal('2')]
    ].sort_by(&:first))
    expect(LedgerVerification.call).to be_passed
  end
end
