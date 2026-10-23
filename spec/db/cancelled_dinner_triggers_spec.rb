# frozen_string_literal: true

require 'rails_helper'

# The database's own rules for a cancelled dinner (ADR 0011 rule 11):
# the functions comeals_reject_settled_child_write and
# comeals_protect_settled_meal in db/structure.sql. Each statement here is raw SQL, the way psql
# or update_all writes, so no model rule runs.
RSpec.describe 'cancelled dinner triggers' do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:ann) { create(:resident, community: community, unit: unit) }
  let(:cid) { create(:resident, community: community, unit: unit) }
  let(:meal) { create(:meal, community: community, date: Reconciliation.latest_cutoff(community.today)) }
  let(:connection) { ActiveRecord::Base.connection }

  # In a savepoint, so the refusal does not end the example's transaction.
  def expect_refused(statement, message)
    expect { ActiveRecord::Base.transaction(requires_new: true) { connection.execute(statement) } }
      .to raise_error(ActiveRecord::StatementInvalid, message)
  end

  def cancel_sql = "UPDATE meals SET cancelled_at = now() WHERE id = #{meal.id}"

  describe 'the rows of a cancelled dinner' do
    let!(:signed_up) { create(:meal_resident, meal: meal, resident: ann, community: community) }
    let!(:bill) { create(:bill, meal: meal, resident: cid, community: community, amount: 0) }

    before { connection.execute(cancel_sql) }

    it 'refuses a new sign-up, a change, a removal, a guest and a cost' do
      cancelled = /meal #{meal.id} is cancelled, and its sign-ups, guests and costs stay as they were/
      expect_refused('INSERT INTO meal_residents (meal_id, resident_id, community_id, multiplier, late, ' \
                     "vegetarian, created_at, updated_at) VALUES (#{meal.id}, #{cid.id}, #{community.id}, 2, " \
                     'false, false, now(), now())', cancelled)
      expect_refused("UPDATE meal_residents SET late = true WHERE id = #{signed_up.id}", cancelled)
      expect_refused("DELETE FROM meal_residents WHERE id = #{signed_up.id}", cancelled)
      expect_refused('INSERT INTO guests (meal_id, resident_id, multiplier, vegetarian, late, created_at, ' \
                     "updated_at) VALUES (#{meal.id}, #{ann.id}, 2, false, false, now(), now())", cancelled)
      expect_refused("UPDATE bills SET no_cost = true WHERE id = #{bill.id}", cancelled)
    end

    it 'refuses a row moved off it onto another dinner' do
      other = create(:meal, community: community, date: meal.date - 1)

      expect_refused("UPDATE meal_residents SET meal_id = #{other.id} WHERE id = #{signed_up.id}",
                     /meal #{meal.id} is cancelled/)
    end

    it 'lets them change once it is restored, and with the repair bypass' do
      connection.execute("UPDATE meals SET cancelled_at = NULL WHERE id = #{meal.id}")
      connection.execute("UPDATE meal_residents SET late = true WHERE id = #{signed_up.id}")
      connection.execute(cancel_sql)

      SettledWrites.with_repair_bypass do
        connection.execute("UPDATE meal_residents SET vegetarian = true WHERE id = #{signed_up.id}")
      end

      expect(signed_up.reload).to have_attributes(late: true, vegetarian: true)
    end
  end

  it 'refuses to cancel a dinner a cook spent money on, and not one whose costs are blank or No cost' do
    blank = create(:bill, meal: meal, resident: cid, community: community, amount: 0)
    create(:bill, meal: meal, resident: ann, community: community, amount: 0, no_cost: true)
    connection.execute(cancel_sql)
    connection.execute("UPDATE meals SET cancelled_at = NULL WHERE id = #{meal.id}")
    connection.execute("UPDATE bills SET amount = 7.25 WHERE id = #{blank.id}")

    expect_refused(cancel_sql, /meal #{meal.id} has a cost with money on it, so it cannot be cancelled/)
  end

  it 'freezes cancelled_at once the dinner is settled' do
    create(:meal_resident, meal: meal, resident: ann, community: community)
    meal.cancel!
    settle!

    expect_refused("UPDATE meals SET cancelled_at = NULL WHERE id = #{meal.id}",
                   /meal #{meal.id} is reconciled; cap, date, cancelled_at and reconciliation_id are frozen/)
  end
end
