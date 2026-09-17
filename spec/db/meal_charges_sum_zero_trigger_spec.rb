# frozen_string_literal: true

require 'rails_helper'

# The database guard that every meal's stored lines sum to zero
# (20260917120000). Every write here skips Rails or goes behind the repair
# bypass on purpose: the trigger exists for the paths a model guard cannot
# see — a rake task, a console, a psql session.
RSpec.describe 'meal charges sum-zero trigger' do
  # The trigger is DEFERRABLE INITIALLY DEFERRED, so it runs at COMMIT.
  # Transactional fixtures never commit, so the examples here really commit
  # and are cleaned up afterwards. Expect "there is no transaction in
  # progress" warnings from the refused commits; they are not a problem.
  include_context 'with no test transaction'

  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:cook) { create(:resident, community: community, unit: unit, multiplier: 2, name: 'Cook') }
  let(:eater) { create(:resident, community: community, unit: unit, multiplier: 2, name: 'Eater') }

  # A settled meal: the cook is credited $80, the two eaters are charged $40
  # each, so its three lines sum to zero.
  let!(:meal) do
    meal = create(:meal, community: community)
    create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('80'))
    create(:meal_resident, meal: meal, resident: cook, community: community)
    create(:meal_resident, meal: meal, resident: eater, community: community)
    settle!(cutoff: Date.yesterday)
    meal.reload
  end

  def extra_line(amount)
    MealCharge.create!(meal: meal, resident: eater, kind: 'guest_debit', amount: amount, multiplier: 1,
                       unit_cost: BigDecimal('40'))
  end

  def repair
    ActiveRecord::Base.transaction do
      ActiveRecord::Base.connection.execute("SET LOCAL comeals.allow_settled_writes = 'on'")
      yield
    end
  end

  it 'lets a settlement commit, because its lines balance' do
    expect(MealCharge.where(meal_id: meal.id).sum(:amount)).to eq(BigDecimal('0'))
  end

  it 'refuses an inserted line that unbalances the meal' do
    expect { extra_line(BigDecimal('-1')) }
      .to raise_error(ActiveRecord::StatementInvalid,
                      /meal #{meal.id} refused: its stored lines sum to -1\.0*, not zero/)
  end

  it 'stores nothing when an unbalancing insert is refused' do
    before_count = MealCharge.where(meal_id: meal.id).count

    suppress(ActiveRecord::StatementInvalid) { extra_line(BigDecimal('-1')) }

    expect(MealCharge.where(meal_id: meal.id).count).to eq(before_count)
  end

  it 'refuses one unit of the grain off, not only a large error' do
    expect { extra_line(BigDecimal('0.00000001')) }
      .to raise_error(ActiveRecord::StatementInvalid, /sum to 0\.00000001, not zero/)
  end

  it 'judges the end of the transaction, not each statement' do
    expect do
      ActiveRecord::Base.transaction do
        extra_line(BigDecimal('-1'))
        # Unbalanced right here, and nothing has complained.
        expect(MealCharge.where(meal_id: meal.id).sum(:amount)).to eq(BigDecimal('-1'))
        extra_line(BigDecimal('1'))
      end
    end.not_to raise_error

    expect(MealCharge.where(meal_id: meal.id).sum(:amount)).to eq(BigDecimal('0'))
  end

  describe 'the repair bypass' do
    it 'lets a deliberate repair rewrite lines that still balance' do
      credit = MealCharge.find_by!(meal_id: meal.id, kind: 'credit')
      debit = MealCharge.find_by!(meal_id: meal.id, kind: 'debit', resident_id: eater.id)

      repair do
        MealCharge.where(id: credit.id).update_all(amount: BigDecimal('81'))
        MealCharge.where(id: debit.id).update_all(amount: BigDecimal('-41'))
      end

      expect(credit.reload.amount).to eq(BigDecimal('81'))
    end

    it 'does not turn the sum-zero check off: a repair that leaves a meal unbalanced is refused' do
      credit = MealCharge.find_by!(meal_id: meal.id, kind: 'credit')

      expect do
        repair { MealCharge.where(id: credit.id).update_all(amount: BigDecimal('81')) }
      end.to raise_error(ActiveRecord::StatementInvalid, /sum to 1\.0*, not zero/)

      expect(credit.reload.amount).to eq(BigDecimal('80'))
    end

    it 'checks a deleted line against the meal it came from' do
      debit = MealCharge.find_by!(meal_id: meal.id, kind: 'debit', resident_id: eater.id)

      expect { repair { MealCharge.where(id: debit.id).delete_all } }
        .to raise_error(ActiveRecord::StatementInvalid, /meal #{meal.id} refused/)
    end
  end
end
