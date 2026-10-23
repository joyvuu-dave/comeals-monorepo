# frozen_string_literal: true

require 'rails_helper'

# The database's own rules for marks on settlement lines (ADR 0011 rule 8):
# the function comeals_protect_settlement_line_mark and the CHECKs on
# settlement_line_marks in db/structure.sql. Each statement here is raw SQL, the way psql
# or update_all writes, so no model rule runs.
RSpec.describe 'settlement line mark triggers' do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:admin) { create(:admin_user, community: community) }
  let(:connection) { ActiveRecord::Base.connection }
  let(:line) do
    cook = create(:resident, community: community, unit: unit)
    meal = create(:meal, community: community, date: Reconciliation.latest_cutoff(community.today))
    create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('30'))
    create(:meal_resident, meal: meal, resident: create(:resident, community: community, unit: unit),
                           community: community)
    settle!.reconciliation_balances.first
  end
  let(:mark) { SettlementLineMarking.mark!(line, status: 'paid', note: 'Cash', by: admin, seen: nil) }

  # In a savepoint, so the refusal does not end the example's transaction.
  def expect_refused(statement, message)
    expect { ActiveRecord::Base.transaction(requires_new: true) { connection.execute(statement) } }
      .to raise_error(ActiveRecord::StatementInvalid, message)
  end

  def insert(status:, note: 'NULL')
    'INSERT INTO settlement_line_marks (reconciliation_balance_id, status, note, admin_user_id, created_at, ' \
      "updated_at) VALUES (#{line.id}, '#{status}', #{note}, #{admin.id}, now(), now())"
  end

  it 'refuses to change or delete a mark' do
    expect_refused("UPDATE settlement_line_marks SET status = 'let_go' WHERE id = #{mark.id}",
                   /a mark is a record of what happened after a settlement/)
    expect_refused("DELETE FROM settlement_line_marks WHERE id = #{mark.id}", /cannot be changed/)
  end

  it 'lets the repair bypass change one' do
    SettledWrites.with_repair_bypass do
      connection.execute("UPDATE settlement_line_marks SET note = 'Check' WHERE id = #{mark.id}")
    end

    expect(mark.reload.note).to eq('Check')
  end

  it 'refuses a status it does not know, and a note of only spaces' do
    expect_refused(insert(status: 'forgiven'), /settlement_line_marks_status_known/)
    expect_refused(insert(status: 'paid', note: "'  '"), /settlement_line_marks_note_not_blank/)
  end

  it 'keeps a marked line from being deleted, even with the repair bypass' do
    mark

    expect do
      ActiveRecord::Base.transaction(requires_new: true) do
        SettledWrites.with_repair_bypass do
          connection.execute("DELETE FROM reconciliation_balances WHERE id = #{line.id}")
        end
      end
    end.to raise_error(ActiveRecord::InvalidForeignKey)
  end
end
