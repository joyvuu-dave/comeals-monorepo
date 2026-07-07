# frozen_string_literal: true

require 'rails_helper'

# Pins issue #26: Postgres triggers backstop reconciled-meal immutability.
# The Rails guards (ReconciledMealImmutability, Meal's frozen-column check)
# stay the first line and fire in normal flows; these triggers make the
# database itself refuse callback-skipping writes (update_all, delete_all,
# update_columns, raw SQL) that would otherwise corrupt settled ledger data.
RSpec.describe 'settled-meal database triggers' do
  let(:community) { create(:community) }

  # A meal with one bill and one attendee, settled through the real
  # settlement path: Reconciliation#assign_meals sweeps it on create.
  # This doubles as proof that the triggers leave settlement itself legal.
  def settled_meal
    meal = create(:meal, community: community)
    create(:bill, meal: meal, community: community)
    create(:meal_resident, meal: meal, community: community)
    create(:reconciliation, community: community)
    meal.reload
    raise 'setup failed: meal was not swept into the reconciliation' unless meal.reconciled?

    meal
  end

  # An open (unreconciled) meal with the same shape, for control examples
  # and as the other end of re-parenting attempts.
  def open_meal
    meal = create(:meal, community: community)
    create(:meal_resident, meal: meal, community: community)
    meal
  end

  describe 'bills of a reconciled meal' do
    it 'refuses update_all' do
      meal = settled_meal
      expect do
        Bill.where(meal_id: meal.id).update_all(amount: 0)
      end.to raise_error(ActiveRecord::StatementInvalid, /reconciled/)
    end

    it 'refuses delete_all' do
      meal = settled_meal
      expect do
        Bill.where(meal_id: meal.id).delete_all
      end.to raise_error(ActiveRecord::StatementInvalid, /reconciled/)
    end

    it 'refuses update_columns' do
      bill = settled_meal.bills.first
      expect do
        bill.update_columns(amount: 0)
      end.to raise_error(ActiveRecord::StatementInvalid, /reconciled/)
    end

    it 'refuses a callback-skipping insert' do
      meal = settled_meal
      cook = create(:resident, community: community)
      expect do
        Bill.insert_all!([{ meal_id: meal.id, resident_id: cook.id, community_id: community.id,
                            amount: 10, created_at: Time.current, updated_at: Time.current }])
      end.to raise_error(ActiveRecord::StatementInvalid, /reconciled/)
    end

    it 'refuses re-parenting a bill off the settled meal' do
      bill = settled_meal.bills.first
      target = open_meal
      expect do
        Bill.where(id: bill.id).update_all(meal_id: target.id)
      end.to raise_error(ActiveRecord::StatementInvalid, /reconciled/)
    end
  end

  describe 'meal_residents of a reconciled meal' do
    it 'refuses update_all' do
      meal = settled_meal
      expect do
        MealResident.where(meal_id: meal.id).update_all(multiplier: 0)
      end.to raise_error(ActiveRecord::StatementInvalid, /reconciled/)
    end

    it 'refuses delete_all' do
      meal = settled_meal
      expect do
        MealResident.where(meal_id: meal.id).delete_all
      end.to raise_error(ActiveRecord::StatementInvalid, /reconciled/)
    end

    it 'refuses update_columns' do
      meal_resident = settled_meal.meal_residents.first
      expect do
        meal_resident.update_columns(multiplier: 0)
      end.to raise_error(ActiveRecord::StatementInvalid, /reconciled/)
    end

    it 'refuses a callback-skipping insert' do
      meal = settled_meal
      eater = create(:resident, community: community)
      expect do
        MealResident.insert_all!([{ meal_id: meal.id, resident_id: eater.id, community_id: community.id,
                                    multiplier: 2, created_at: Time.current, updated_at: Time.current }])
      end.to raise_error(ActiveRecord::StatementInvalid, /reconciled/)
    end

    it 'refuses re-parenting attendance off the settled meal' do
      meal_resident = settled_meal.meal_residents.first
      target = open_meal
      expect do
        MealResident.where(id: meal_resident.id).update_all(meal_id: target.id)
      end.to raise_error(ActiveRecord::StatementInvalid, /reconciled/)
    end

    it 'refuses re-parenting attendance onto the settled meal' do
      meal = settled_meal
      # A different resident than the settled meal's attendee, so the
      # unique (meal_id, resident_id) index cannot fire before the trigger.
      other = create(:meal_resident, meal: open_meal, community: community)
      expect do
        MealResident.where(id: other.id).update_all(meal_id: meal.id)
      end.to raise_error(ActiveRecord::StatementInvalid, /reconciled/)
    end
  end

  describe 'guests of a reconciled meal' do
    def settled_meal_with_guest
      meal = create(:meal, community: community)
      create(:bill, meal: meal, community: community)
      guest = create(:guest, meal: meal)
      create(:reconciliation, community: community)
      raise 'setup failed: meal was not swept into the reconciliation' unless meal.reload.reconciled?

      guest
    end

    it 'refuses update_all' do
      guest = settled_meal_with_guest
      expect do
        Guest.where(meal_id: guest.meal_id).update_all(multiplier: 0)
      end.to raise_error(ActiveRecord::StatementInvalid, /reconciled/)
    end

    it 'refuses delete_all' do
      guest = settled_meal_with_guest
      expect do
        Guest.where(meal_id: guest.meal_id).delete_all
      end.to raise_error(ActiveRecord::StatementInvalid, /reconciled/)
    end

    it 'refuses update_columns' do
      guest = settled_meal_with_guest
      expect do
        guest.update_columns(multiplier: 0)
      end.to raise_error(ActiveRecord::StatementInvalid, /reconciled/)
    end

    it 'refuses a callback-skipping insert' do
      meal = settled_meal
      host = create(:resident, community: community)
      expect do
        Guest.insert_all!([{ meal_id: meal.id, resident_id: host.id, multiplier: 2,
                             created_at: Time.current, updated_at: Time.current }])
      end.to raise_error(ActiveRecord::StatementInvalid, /reconciled/)
    end
  end

  describe 'the reconciled meal row itself' do
    it 'refuses update_all on cap (frozen settlement input)' do
      meal = settled_meal
      expect do
        Meal.where(id: meal.id).update_all(cap: 1)
      end.to raise_error(ActiveRecord::StatementInvalid, /reconciled/)
    end

    it 'refuses update_all on date (frozen settlement input)' do
      meal = settled_meal
      expect do
        Meal.where(id: meal.id).update_all(date: Date.new(2000, 1, 1))
      end.to raise_error(ActiveRecord::StatementInvalid, /reconciled/)
    end

    it 'refuses un-reconciling (reconciliation_id id -> nil)' do
      meal = settled_meal
      expect do
        Meal.where(id: meal.id).update_all(reconciliation_id: nil)
      end.to raise_error(ActiveRecord::StatementInvalid, /reconciled/)
    end

    it 'refuses re-pointing at a different reconciliation (id -> other id)' do
      meal = settled_meal
      other = create(:reconciliation, community: community)
      expect do
        Meal.where(id: meal.id).update_all(reconciliation_id: other.id)
      end.to raise_error(ActiveRecord::StatementInvalid, /reconciled/)
    end

    it 'refuses DELETE' do
      meal = settled_meal
      expect do
        Meal.where(id: meal.id).delete_all
      end.to raise_error(ActiveRecord::StatementInvalid, /reconciled/)
    end

    it 'still allows updates to columns that are not settlement inputs' do
      meal = settled_meal
      Meal.where(id: meal.id).update_all(description: 'corrected description')
      expect(meal.reload.description).to eq('corrected description')
    end
  end

  describe 'legal settlement writes (control)' do
    it 'allows claiming an unreconciled meal via update_all (nil -> id, the assign_meals shape)' do
      meal = create(:meal, community: community) # no bill, so the factory reconciliation does not sweep it
      reconciliation = create(:reconciliation, community: community)

      claimed = Meal.where(id: meal.id, reconciliation_id: nil).update_all(reconciliation_id: reconciliation.id)

      expect(claimed).to eq(1)
      expect(meal.reload).to be_reconciled
    end

    it 'allows deleting an unreconciled meal' do
      meal = create(:meal, community: community)
      expect { Meal.where(id: meal.id).delete_all }.to change(Meal, :count).by(-1)
    end
  end

  describe 'child rows of an unreconciled meal (control)' do
    it 'still allows callback-skipping writes' do
      meal = open_meal
      create(:bill, meal: meal, community: community)

      Bill.where(meal_id: meal.id).update_all(amount: 1)
      MealResident.where(meal_id: meal.id).update_all(multiplier: 1)
      Bill.where(meal_id: meal.id).delete_all
      MealResident.where(meal_id: meal.id).delete_all

      expect(meal.reload.attendees_count).to eq(0)
      expect(meal.bills.count).to eq(0)
    end
  end

  describe 'schema completeness' do
    # The test database is built from db/structure.sql, so this pins that a
    # fresh database created from the dumped schema carries the triggers.
    # If it fails, the schema format has regressed to one that cannot
    # represent triggers (issue #26) — databases built from it would
    # silently lack the backstop.
    it 'carries every settled-data trigger in a database built from structure.sql' do
      trigger_names = ActiveRecord::Base.connection.select_values(<<~SQL.squish)
        SELECT tgname FROM pg_trigger WHERE NOT tgisinternal ORDER BY tgname
      SQL

      expect(trigger_names).to include(
        'bills_reject_settled_write',
        'meal_residents_reject_settled_write',
        'guests_reject_settled_write',
        'meals_protect_settled',
        # From 20260408000002. Lost from the dev database once (a schema.rb
        # rebuild cannot carry triggers — the drift that motivated the
        # structure.sql switch), so pin it here with the rest.
        'prevent_community_delete'
      )
    end
  end

  describe 'the deliberate repair bypass (comeals.allow_settled_writes)' do
    # These examples prove the bypass is transaction-scoped: the flag must
    # die with its transaction, on commit and on rollback alike. That needs
    # real transactions, so this group opts out of transactional fixtures
    # (which would wrap everything in one never-committed transaction) and
    # cleans up its committed rows itself, like the billing snapshot spec.
    self.use_transactional_tests = false

    after do
      ActiveRecord::Base.transaction do
        ActiveRecord::Base.connection.execute("SET LOCAL comeals.allow_settled_writes = 'on'")
        Audited::Audit.delete_all
        Bill.delete_all
        MealResident.delete_all
        Guest.delete_all
        ReconciliationBalance.delete_all
        Meal.delete_all
        Reconciliation.delete_all
        Key.delete_all
        Resident.delete_all
        Unit.delete_all
        # DELETE on communities is refused by prevent_community_delete
        # (20260408000002), which has no bypass. TRUNCATE does not fire
        # row-level triggers; every referencing table is already empty.
        ActiveRecord::Base.connection.execute('TRUNCATE communities CASCADE')
      end
    end

    def repair
      ActiveRecord::Base.transaction do
        ActiveRecord::Base.connection.execute("SET LOCAL comeals.allow_settled_writes = 'on'")
        yield
      end
    end

    it 'allows an otherwise-refused write inside a SET LOCAL transaction' do
      bill = settled_meal.bills.first

      repair { Bill.where(id: bill.id).update_all(amount: 42) }

      expect(bill.reload.amount).to eq(BigDecimal('42'))
    end

    it 'restores the guard once the repair transaction commits' do
      bill = settled_meal.bills.first

      repair { Bill.where(id: bill.id).update_all(amount: 42) }

      expect do
        Bill.where(id: bill.id).update_all(amount: 43)
      end.to raise_error(ActiveRecord::StatementInvalid, /reconciled/)
    end

    it 'restores the guard after a rolled-back repair transaction' do
      bill = settled_meal.bills.first
      original_amount = bill.amount

      repair do
        Bill.where(id: bill.id).update_all(amount: 42)
        raise ActiveRecord::Rollback
      end

      expect(bill.reload.amount).to eq(original_amount)
      expect do
        Bill.where(id: bill.id).update_all(amount: 43)
      end.to raise_error(ActiveRecord::StatementInvalid, /reconciled/)
    end
  end
end
