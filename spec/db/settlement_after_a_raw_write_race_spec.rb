# frozen_string_literal: true

require 'rails_helper'

# Issue #43 from the other side. spec/db/settlement_race_spec.rb starts
# the settlement first: it claims the meal FOR UPDATE, and a raw write
# that comes after it waits and is then refused by the trigger. Here the
# raw write comes first. It is raw SQL on a libpq session of its own, the
# way psql writes, at READ COMMITTED, and its transaction is still open
# when the settlement starts.
#
# The trigger's lookup holds the meal FOR KEY SHARE, so the settlement
# waits at its FOR UPDATE until the write commits. Then it must count the
# new row. ADR 0003 says it does: "under READ COMMITTED each statement
# takes a fresh snapshot". But since ADR 0005 the settlement runs at
# SERIALIZABLE, so its snapshot is taken when its first statement starts,
# before the wait, and it does not see the row. The raw write ran at READ
# COMMITTED, so PostgreSQL's conflict check does not see it either, and
# the lock it held changed no row of meals, so the wait ends with no
# conflict. The settlement then commits balances that leave the row out.
RSpec.describe 'a settlement that starts while a raw write to its meal is still open' do
  include_context 'with no test transaction'

  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:latest) { Reconciliation.latest_cutoff(community.today) }
  let(:meal) { create(:meal, community: community, date: latest) }
  let(:cook) { create(:resident, community: community, unit: unit, multiplier: 2) }
  let(:eater) { create(:resident, community: community, unit: unit, multiplier: 2) }
  let(:latecomer) { create(:resident, community: community, unit: unit, multiplier: 2) }
  # Signed up too, so the meal still has someone to charge when the
  # second example takes the eater off it.
  let(:neighbour) { create(:resident, community: community, unit: unit, multiplier: 2) }

  before do
    create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('30'))
    create(:meal_resident, meal: meal, resident: eater, community: community)
    create(:meal_resident, meal: meal, resident: neighbour, community: community)
    latecomer
  end

  def open_session
    db = ActiveRecord::Base.connection_db_config.configuration_hash
    PG.connect(host: db[:host], port: db[:port], user: db[:username], password: db[:password], dbname: db[:database])
  end

  # The real settlement, in a thread, on a Rails connection of its own.
  # The thread's value is :settled, or the error.
  def settle_alone
    Thread.new do
      Thread.current.report_on_exception = false
      ActiveRecord::Base.connection_pool.with_connection do
        SettleAndNotify.call(cutoff: latest)
        :settled
      end
    rescue StandardError => e
      "#{e.class}: #{e.message.lines.first&.strip}"
    end
  end

  def waited_for_a_lock?(thread, observer)
    200.times do
      return false unless thread.alive?

      waiting = observer.exec(
        'SELECT count(*) FROM pg_stat_activity WHERE datname = current_database() ' \
        "AND pid <> pg_backend_pid() AND wait_event_type = 'Lock'"
      ).getvalue(0, 0).to_i.positive?
      return true if waiting

      sleep 0.02
    end
    false
  end

  # Opens a transaction on a raw session, runs `sql` in it, starts the
  # settlement, and commits the raw write while the settlement waits.
  # Returns how the settlement ended, and whether it waited.
  def settle_during(sql)
    observer = open_session
    writer = open_session
    writer.exec('BEGIN')
    writer.exec(sql)
    settling = settle_alone
    waited = waited_for_a_lock?(settling, observer)
    writer.exec('COMMIT')
    [settling.value, waited]
  ensure
    writer&.close
    observer&.close
  end

  # What the settlement stored for the meal, against what the meal's rows
  # say now. These must match whenever the meal is settled.
  def stored_and_from_rows
    reconciliation = Reconciliation.find(Meal.find(meal.id).reconciliation_id)
    stored = reconciliation.reconciliation_balances.pluck(:resident_id, :amount).to_h
    from_rows = reconciliation.settlement_balances.reject { |_, amount| amount.zero? }
    [stored, from_rows]
  end

  it 'counts a sign-up that was being added when it started' do
    outcome, waited = settle_during(<<~SQL.squish)
      INSERT INTO meal_residents (meal_id, resident_id, community_id, multiplier, late, vegetarian,
                                  created_at, updated_at)
      VALUES (#{meal.id}, #{latecomer.id}, #{community.id}, 2, false, false, now(), now())
    SQL

    expect(outcome).to eq(:settled)
    expect(waited).to be(true)
    stored, from_rows = stored_and_from_rows
    expect(stored).to eq(from_rows),
                      "the settlement stored #{stored.transform_values { |a| a.to_s('F') }}, but the meal's rows " \
                      "say #{from_rows.transform_values { |a| a.to_s('F') }}: the latecomer eats for free"
  end

  it 'leaves out a sign-up that was being removed when it started' do
    outcome, waited = settle_during(
      "DELETE FROM meal_residents WHERE meal_id = #{meal.id} AND resident_id = #{eater.id}"
    )

    expect(outcome).to eq(:settled)
    expect(waited).to be(true)
    stored, from_rows = stored_and_from_rows
    expect(stored).to eq(from_rows),
                      "the settlement stored #{stored.transform_values { |a| a.to_s('F') }}, but the meal's rows " \
                      "say #{from_rows.transform_values { |a| a.to_s('F') }}: someone is charged for a dinner " \
                      'the rows say they did not eat'
  end
end
