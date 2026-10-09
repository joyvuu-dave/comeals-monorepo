# frozen_string_literal: true

require 'rails_helper'

# Only a settlement adds line items and settled balances (migration
# 20261009120000).
#
# The protect triggers refuse every UPDATE and DELETE on meal_charges and
# reconciliation_balances. Before this migration they let every INSERT
# through, and the sum-zero triggers accept any insert that still adds up
# to zero. So two new rows that cancel out could be added to a settled meal
# from a console or psql: a $5 credit for Ann and a $5 guest charge for
# Bob. Ann's settled statement would change, and only the nightly line-item
# check would see it, the next morning.
#
# Now Settlement#write_ledger! sets a setting that lasts only for its own
# transaction and names its reconciliation
# (Settlement::SETTLING_SETTING). An insert is refused unless that setting
# names the reconciliation the row belongs to, or the repair bypass is on.
#
# Every write here is plain SQL, the way a psql session would send it.
RSpec.describe 'inserts into the settled ledger' do
  # The rows really commit, so the deferred sum-zero triggers run too, and
  # each example shows what the database keeps after COMMIT. Under the
  # usual test transaction nothing commits, so a balanced insert would pass
  # those triggers here without proving anything.
  include_context 'with no test transaction'

  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:carl) { create(:resident, community: community, unit: unit, multiplier: 2, name: 'Carl') }
  let(:ann) { create(:resident, community: community, unit: unit, multiplier: 2, name: 'Ann') }
  let(:bob) { create(:resident, community: community, unit: unit, multiplier: 2, name: 'Bob') }

  # Carl cooked for $80, and Ann and Bob ate. Carl is credited $80, Ann and
  # Bob are charged $40 each.
  let!(:meal) { meal_on(Date.yesterday - 1) }
  let!(:reconciliation) { settle!(cutoff: Date.yesterday - 1) }

  def meal_on(date)
    meal = create(:meal, community: community, date: date)
    create(:bill, meal: meal, resident: carl, amount: BigDecimal('80'))
    create(:meal_resident, meal: meal, resident: ann)
    create(:meal_resident, meal: meal, resident: bob)
    meal
  end

  def sql(statement)
    ActiveRecord::Base.connection.execute(statement)
  end

  # Two lines that add up to zero: Ann is credited $5, and Bob is charged
  # $5 for a guest. Ann has no credit on the meal yet and a guest line is
  # never unique, so no unique index stops them. Only the new rule can.
  def insert_two_balancing_lines(meal)
    sql(<<~SQL.squish)
      INSERT INTO meal_charges
        (meal_id, resident_id, kind, amount, multiplier, unit_cost, bill_amount, created_at, updated_at)
      VALUES
        (#{meal.id}, #{ann.id}, 'credit', 5, NULL, 20, 5, now(), now()),
        (#{meal.id}, #{bob.id}, 'guest_debit', -5, 1, 20, NULL, now(), now())
    SQL
  end

  # Two balances that add up to zero, for two people the settlement left
  # without one, so the unique index on (reconciliation, resident) does not
  # stop them.
  def insert_two_balancing_balances(reconciliation)
    dee = create(:resident, community: community, unit: unit, name: 'Dee')
    eve = create(:resident, community: community, unit: unit, name: 'Eve')
    sql(<<~SQL.squish)
      INSERT INTO reconciliation_balances (reconciliation_id, resident_id, amount, created_at, updated_at)
      VALUES (#{reconciliation.id}, #{dee.id}, 5, now(), now()),
             (#{reconciliation.id}, #{eve.id}, -5, now(), now())
    SQL
  end

  def lines_of(meal)
    MealCharge.where(meal_id: meal.id).order(:id).pluck(:resident_id, :kind, :amount)
  end

  def balances_of(reconciliation)
    ReconciliationBalance.where(reconciliation_id: reconciliation.id).order(:resident_id).pluck(:resident_id, :amount)
  end

  describe 'line items' do
    it 'refuses two lines that add up to zero on a settled meal' do
      expect { insert_two_balancing_lines(meal) }
        .to raise_error(ActiveRecord::StatementInvalid,
                        /INSERT on meal_charges refused: .*meal #{meal.id}\b.*settled-data-repair/)
    end

    it 'keeps the settled lines as they were' do
      before = lines_of(meal)

      suppress(ActiveRecord::StatementInvalid) { insert_two_balancing_lines(meal) }

      expect(lines_of(meal)).to eq(before)
    end

    # No meal gets a line before it is settled. A line already sitting on
    # an open meal is one the nightly check cannot see (it reads only the
    # lines of settled meals), and it can take the place of a real line
    # when the meal is settled.
    #
    # The refusal says the meal is not settled. The words for a settled
    # meal ("corrections belong in the next reconciliation") would be wrong
    # advice here: an open meal is corrected by changing its bills and
    # attendance.
    it 'refuses a line on a meal that is not settled' do
      open_meal = meal_on(community.today)

      expect { insert_two_balancing_lines(open_meal) }
        .to raise_error(ActiveRecord::StatementInvalid,
                        /INSERT on meal_charges refused: meal #{open_meal.id} is not settled\./)
      expect(lines_of(open_meal)).to be_empty
    end

    # The foreign key would refuse it too, but the trigger runs first, so
    # its words are the ones a person sees. They must not call a meal that
    # is not there "not settled".
    it 'refuses a line on a meal that does not exist, and says so' do
      missing_id = Meal.maximum(:id) + 1000

      expect do
        sql(<<~SQL.squish)
          INSERT INTO meal_charges
            (meal_id, resident_id, kind, amount, multiplier, unit_cost, bill_amount, created_at, updated_at)
          VALUES (#{missing_id}, #{ann.id}, 'credit', 0, NULL, 0, 0, now(), now())
        SQL
      end.to raise_error(ActiveRecord::StatementInvalid,
                         /INSERT on meal_charges refused: there is no meal #{missing_id}\./)
    end

    # The setting names one reconciliation. Setting it for a different one
    # does not open this one's meals.
    it "refuses a line while the setting names another reconciliation's settlement" do
      meal_on(Date.yesterday)
      other = settle!(cutoff: Date.yesterday)

      expect { as_settlement_of(other) { insert_two_balancing_lines(meal) } }
        .to raise_error(ActiveRecord::StatementInvalid, /INSERT on meal_charges refused/)
    end
  end

  describe 'settled balances' do
    it 'refuses two balances that add up to zero on a settled reconciliation' do
      refusal = /INSERT on reconciliation_balances refused: .*reconciliation #{reconciliation.id}\b.*data-repair/

      expect { insert_two_balancing_balances(reconciliation) }.to raise_error(ActiveRecord::StatementInvalid, refusal)
    end

    it 'keeps the settled balances as they were' do
      before = balances_of(reconciliation)

      suppress(ActiveRecord::StatementInvalid) { insert_two_balancing_balances(reconciliation) }

      expect(balances_of(reconciliation)).to eq(before)
    end

    it "refuses a balance while the setting names another reconciliation's settlement" do
      meal_on(Date.yesterday)
      other = settle!(cutoff: Date.yesterday)

      expect { as_settlement_of(other) { insert_two_balancing_balances(reconciliation) } }
        .to raise_error(ActiveRecord::StatementInvalid, /INSERT on reconciliation_balances refused/)
    end
  end

  describe 'the settlement itself' do
    it 'still writes its lines and balances' do
      expect(lines_of(meal)).to contain_exactly(
        [carl.id, 'credit', BigDecimal('80')],
        [ann.id, 'debit', BigDecimal('-40')],
        [bob.id, 'debit', BigDecimal('-40')]
      )
      expect(balances_of(reconciliation)).to contain_exactly(
        [carl.id, BigDecimal('80')], [ann.id, BigDecimal('-40')], [bob.id, BigDecimal('-40')]
      )
    end

    # The setting lasts until the end of the transaction unless the
    # settlement turns it off. A settlement that left it on would let any
    # later write in the same transaction add lines to the meals it just
    # settled, or balances to the reconciliation it just made. One example
    # per table, because the first refused insert ends the transaction.
    describe 'turning its setting off when it is done' do
      it 'refuses a later line item in the same transaction' do
        later_meal = meal_on(Date.yesterday)

        expect do
          ActiveRecord::Base.transaction do
            settle!(cutoff: Date.yesterday)
            insert_two_balancing_lines(later_meal)
          end
        end.to raise_error(ActiveRecord::StatementInvalid, /INSERT on meal_charges refused/)
      end

      it 'refuses a later balance in the same transaction' do
        meal_on(Date.yesterday)

        expect do
          ActiveRecord::Base.transaction do
            settled = settle!(cutoff: Date.yesterday)
            insert_two_balancing_balances(settled)
          end
        end.to raise_error(ActiveRecord::StatementInvalid, /INSERT on reconciliation_balances refused/)
      end
    end
  end

  describe 'the repair bypass' do
    it 'still lets a repair add lines and balances that add up to zero' do
      with_repair_bypass do
        insert_two_balancing_lines(meal)
        insert_two_balancing_balances(reconciliation)
      end

      expect(lines_of(meal).size).to eq(5)
      expect(balances_of(reconciliation).size).to eq(5)
    end
  end
end
