# frozen_string_literal: true

require 'rails_helper'

# The "Mark these blank costs as No cost" button changes only costs that
# are still blank at the moment of the yes (ADR 0011 rule 4). This races
# it against a cook's cost written at that same moment, and the cost
# must win: it is never marked No cost.
#
# The cook's write is raw SQL on a libpq session of its own, at READ
# COMMITTED, the way psql writes: it takes no meal lock of its own, only
# the one the settled-meal trigger takes, and it does not touch the meal
# row. That is the hardest case. The marking's transaction began before
# the write committed, so its first read of the cost is the old, blank
# one, and only the database's conflict check stops it from writing over
# the new cost. RetryOnConflict then reads the cost again and leaves it
# alone.
RSpec.describe 'marking blank costs No cost, against a cost entered at the same moment' do
  include_context 'with no test transaction'

  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:meal) { create(:meal, community: community, date: Reconciliation.latest_cutoff(community.today)) }
  let(:bill) do
    create(:bill, meal: meal, resident: create(:resident, community: community, unit: unit), community: community,
                  amount: BigDecimal('0'))
  end

  before { create(:meal_resident, meal: meal, resident: create(:resident, community: community, unit: unit)) }

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

  it 'leaves the cost alone, and never marks it No cost' do
    allow(Rails.error).to receive(:report).and_call_original
    cook = open_session
    observer = open_session
    cook.exec('BEGIN')
    cook.exec_params('UPDATE bills SET amount = 12 WHERE id = $1', [bill.id])

    marking = Thread.new do
      Thread.current.report_on_exception = false
      ActiveRecord::Base.connection_pool.with_connection { NoCostMarking.call(bill_ids: [bill.id]) }
    end
    # The cook's update holds the meal's FOR KEY SHARE lock (the trigger),
    # so the marking waits at its FOR UPDATE until the cook commits.
    expect(wait_for_blocked_session(observer, 'FOR UPDATE')).to be(true)
    cook.exec('COMMIT')
    result = marking.value

    expect(result.marked).to eq([])
    expect(result.left_alone.map(&:reason)).to eq(['the cook entered a cost'])
    expect(bill.reload).to have_attributes(amount: BigDecimal('12'), no_cost: false)
    # The first try read the old, blank cost, and the database refused its
    # write; the second try read the cost again (RetryOnConflict).
    expect(Rails.error).to have_received(:report)
      .with(an_instance_of(ActiveRecord::SerializationFailure), hash_including(handled: true)).once
  ensure
    cook&.close
    observer&.close
  end
end
