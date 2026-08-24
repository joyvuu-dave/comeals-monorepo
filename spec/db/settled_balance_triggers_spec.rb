# frozen_string_literal: true

require 'rails_helper'

# The database guards on reconciliation_balances (20260731120000).
#
# Every write here skips Rails on purpose — update_all, delete_all, raw SQL.
# The model guards on ReconciliationBalance are what a person using the app
# hits, and they are covered in spec/models/reconciliation_balance_spec.rb.
# These examples are about the paths that skip callbacks entirely — a rake
# task, a console, a psql session — because that is the only reason the
# triggers exist.
RSpec.describe 'settled balance triggers' do
  # Two reasons this group cannot run inside the usual test transaction.
  #
  # The zero-sum trigger is DEFERRABLE INITIALLY DEFERRED, so it runs at
  # COMMIT. Transactional fixtures never commit, and releasing a savepoint is
  # not a commit, so the check would never fire and every example about it
  # would pass without testing anything.
  #
  # And a statement refused by a trigger aborts the transaction it is in. With
  # autocommit that is only the failed statement, so the examples can go on to
  # ask what the row looks like afterwards.
  include_context 'with no test transaction'

  # This file prints four "WARNING: there is no transaction in progress" lines
  # and that is expected, not a problem to chase. A deferred constraint fails
  # during COMMIT, which ends the transaction on the spot; ActiveRecord then
  # sends its own ROLLBACK and PostgreSQL says there is nothing to roll back.
  # One line per example whose commit is refused, and there are four of those.

  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }

  # A settled reconciliation with real balances: the cook is owed $40, the
  # eater owes $40.
  let!(:reconciliation) do
    cook = create(:resident, community: community, unit: unit, multiplier: 2, name: 'Cook')
    eater = create(:resident, community: community, unit: unit, multiplier: 2, name: 'Eater')

    meal = create(:meal, community: community)
    create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('80'))
    create(:meal_resident, meal: meal, resident: cook, community: community, multiplier: 2)
    create(:meal_resident, meal: meal, resident: eater, community: community, multiplier: 2)

    settle!(community, cutoff: Date.yesterday)
  end

  let(:balance) { reconciliation.reconciliation_balances.order(:resident_id).first }
  let(:other_balance) { reconciliation.reconciliation_balances.order(:resident_id).last }

  def new_resident(name)
    create(:resident, community: community, unit: unit, multiplier: 2, name: name)
  end

  describe 'rewriting a settled amount' do
    it 'refuses an UPDATE that skips Rails' do
      expect { ReconciliationBalance.where(id: balance.id).update_all(amount: BigDecimal('5')) }
        .to raise_error(ActiveRecord::StatementInvalid, /reconciliation_balances refused/)
    end

    it 'refuses a DELETE that skips Rails' do
      expect { ReconciliationBalance.where(id: balance.id).delete_all }
        .to raise_error(ActiveRecord::StatementInvalid, /reconciliation_balances refused/)
    end

    it 'names the reconciliation and points at the runbook' do
      expect { ReconciliationBalance.where(id: balance.id).delete_all }
        .to raise_error(ActiveRecord::StatementInvalid,
                        /reconciliation #{reconciliation.id} is settled.*settled-data-repair/m)
    end

    it 'leaves the amount untouched after a refused update' do
      before_amount = balance.amount

      suppress(ActiveRecord::StatementInvalid) do
        ReconciliationBalance.where(id: balance.id).update_all(amount: BigDecimal('5'))
      end

      expect(balance.reload.amount).to eq(before_amount)
    end
  end

  describe 'the books must still add up' do
    # The insert path is the one the first trigger cannot judge: settlement
    # writes its rows one at a time, so a row-level BEFORE trigger cannot
    # tell settlement's own inserts from one added months later. The deferred
    # constraint catches it at commit instead, by the only thing that
    # separates them — whether the reconciliation still balances.
    it 'refuses an inserted balance that unbalances the reconciliation' do
      expect do
        ReconciliationBalance.create!(
          reconciliation: reconciliation, resident: new_resident('Stranger'), amount: BigDecimal('10')
        )
      end.to raise_error(ActiveRecord::StatementInvalid, /sum to 10\.0*, not zero/)
    end

    it 'stores nothing when an unbalancing insert is refused' do
      before_count = reconciliation.reconciliation_balances.count

      suppress(ActiveRecord::StatementInvalid) do
        ReconciliationBalance.create!(
          reconciliation: reconciliation, resident: new_resident('Stranger'), amount: BigDecimal('10')
        )
      end

      expect(reconciliation.reconciliation_balances.count).to eq(before_count)
    end

    # This is also what makes the check usable at all: the ledger is allowed
    # to be unbalanced in the middle of a transaction, because the only state
    # that matters is the one that commits. Settlement itself depends on it —
    # it inserts one row at a time, and is unbalanced until the last one.
    it 'judges the end of the transaction, not each statement' do
      one = new_resident('One')
      two = new_resident('Two')

      expect do
        ActiveRecord::Base.transaction do
          ReconciliationBalance.create!(reconciliation: reconciliation, resident: one, amount: BigDecimal('10'))

          # Unbalanced right here, and nothing has complained.
          expect(reconciliation.reconciliation_balances.sum(:amount)).to eq(BigDecimal('10'))

          ReconciliationBalance.create!(reconciliation: reconciliation, resident: two, amount: BigDecimal('-10'))
        end
      end.not_to raise_error

      expect(reconciliation.reconciliation_balances.sum(:amount)).to eq(BigDecimal('0'))
    end
  end

  describe 'the repair bypass' do
    def repair
      ActiveRecord::Base.transaction do
        ActiveRecord::Base.connection.execute("SET LOCAL comeals.allow_settled_writes = 'on'")
        yield
      end
    end

    it 'lets a deliberate repair rewrite a settled amount' do
      moved = balance.amount + BigDecimal('1')

      repair do
        ReconciliationBalance.where(id: balance.id).update_all(amount: moved)
        ReconciliationBalance.where(id: other_balance.id).update_all(amount: other_balance.amount - BigDecimal('1'))
      end

      expect(balance.reload.amount).to eq(moved)
    end

    # The bypass exists so genuine corruption can be corrected. It does not
    # exist to let a repair leave the books not adding up, so the zero-sum
    # trigger ignores it. This is the one rule with no way around it.
    it 'still refuses a repair that leaves the reconciliation unbalanced' do
      expect do
        repair do
          ReconciliationBalance.where(id: balance.id).update_all(amount: balance.amount + BigDecimal('1'))
        end
      end.to raise_error(ActiveRecord::StatementInvalid, /not zero/)
    end

    # The rebuild recipe in docs/runbooks/settled-data-repair.md, run exactly
    # as written. A runbook step nobody has run is a guess, and this one is
    # only ever reached during an incident, which is the worst moment to find
    # out that Settlement#rewrite! no longer clears the tables for you.
    it 'rebuilds one reconciliation the way the runbook says' do
      before_amounts = reconciliation.reconciliation_balances.order(:resident_id).pluck(:amount)
      before_lines = MealCharge.for_reconciliation(reconciliation).count

      repair do
        MealCharge.for_reconciliation(reconciliation).delete_all
        reconciliation.reconciliation_balances.delete_all
        Settlement.new(reconciliation).rewrite!
      end

      expect(reconciliation.reconciliation_balances.order(:resident_id).pluck(:amount)).to eq(before_amounts)
      expect(MealCharge.for_reconciliation(reconciliation).count).to eq(before_lines)
    end

    it 'keeps the original amounts when an unbalanced repair is refused' do
      before_amount = balance.amount

      suppress(ActiveRecord::StatementInvalid) do
        repair do
          ReconciliationBalance.where(id: balance.id).update_all(amount: before_amount + BigDecimal('1'))
        end
      end

      expect(balance.reload.amount).to eq(before_amount)
    end
  end

  describe 'settlement itself' do
    it 'still writes a balanced ledger through both triggers' do
      expect(reconciliation.reconciliation_balances.count).to eq(2)
      expect(reconciliation.reconciliation_balances.sum(:amount)).to eq(BigDecimal('0'))
      expect(reconciliation.reconciliation_balances.pluck(:amount).map(&:abs).uniq).to eq([BigDecimal('40')])
    end
  end
end
