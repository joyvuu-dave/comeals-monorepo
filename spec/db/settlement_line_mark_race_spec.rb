# frozen_string_literal: true

require 'rails_helper'

# Two admins mark the same settlement line at the same moment, each on a
# page that showed the line with no mark (ADR 0011 rule 8). The first
# change is saved. The second must not be saved next to it: its page did
# not see the first mark, so it is refused (SettlementLineMarking::Changed)
# and the admin sees the page as it is now.
#
# The first change holds the line's row lock while it saves. The second
# waits at its own lock until the first commits. Its transaction began
# before that commit, so it reads the line's marks without the first one,
# and the database refuses it for a conflict (ADR 0005). RetryOnConflict
# runs it again, and the new try sees the first mark and is refused.
# Real threads on real connections, because the test transaction would
# put both changes in one transaction, where nothing waits.
RSpec.describe 'two marks on one settlement line at the same moment' do
  include_context 'with no test transaction'

  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:first_admin) { create(:admin_user, community: community) }
  let(:second_admin) { create(:admin_user, community: community) }
  let(:line) do
    meal = create(:meal, community: community, date: Reconciliation.latest_cutoff(community.today))
    create(:bill, meal: meal, resident: create(:resident, community: community, unit: unit), community: community,
                  amount: BigDecimal('30'))
    eater = create(:resident, community: community, unit: unit)
    create(:meal_resident, meal: meal, resident: eater, community: community)
    settle!.reconciliation_balances.find_by!(resident: eater)
  end

  def open_session
    db = ActiveRecord::Base.connection_db_config.configuration_hash
    PG.connect(host: db[:host], port: db[:port], user: db[:username], password: db[:password], dbname: db[:database])
  end

  # Waits until another session is blocked on a lock while running a
  # statement that contains `sql_fragment`.
  def wait_for_blocked_session(observer, sql_fragment)
    200.times do
      blocked = observer.exec_params(
        'SELECT count(*) FROM pg_stat_activity WHERE datname = current_database() ' \
        "AND pid <> pg_backend_pid() AND wait_event_type = 'Lock' AND query LIKE $1",
        ["%#{sql_fragment}%"]
      ).getvalue(0, 0).to_i.positive?
      return true if blocked

      sleep 0.02
    end
    false
  end

  def mark(by)
    SettlementLineMarking.mark!(ReconciliationBalance.find(line.id), status: 'paid', note: nil, by: by, seen: nil)
  end

  it 'makes the second change wait for the first, then refuses it, because its page did not see the first' do
    observer = open_session
    second = nil
    blocked = false
    # The first change stops after its checks, while it holds the line's
    # lock, and starts the second change on a connection of its own.
    allow(SettlementLineMarking).to receive(:refuse_no_change!).and_wrap_original do |original, newest, mark|
      original.call(newest, mark)
      if mark.admin_user_id == first_admin.id
        second = Thread.new do
          Thread.current.report_on_exception = false
          ActiveRecord::Base.connection_pool.with_connection { mark(second_admin) }
        end
        blocked = wait_for_blocked_session(observer, 'FOR UPDATE')
      end
    end

    allow(Rails.error).to receive(:report).and_call_original
    made = mark(first_admin)

    expect(blocked).to be(true)
    expect { second.value }.to raise_error(SettlementLineMarking::Changed)
    expect(SettlementLineMark.where(reconciliation_balance_id: line.id).pluck(:id)).to eq([made.id])
    expect(Rails.error).to have_received(:report)
      .with(an_instance_of(ActiveRecord::SerializationFailure), hash_including(handled: true)).once
  ensure
    # A second change that is still waiting gets 10 seconds to end.
    second.join(10) if second&.alive?
    observer&.close
  end
end
