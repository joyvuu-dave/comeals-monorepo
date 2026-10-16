# frozen_string_literal: true

require 'rails_helper'

# A dinner a cook spent money on cannot be cancelled (ADR 0011 rule 11).
# Migration 20261010125954 holds that rule in the database too, for a
# write that skips the model:
#
#   - comeals_protect_settled_meal refuses a cancel when a bill of the
#     dinner has money on it;
#   - comeals_reject_settled_child_write refuses a cost on a cancelled
#     dinner.
#
# Each rule reads the other writer's row. A cost and a cancel at the same
# moment must not both go through: whichever comes second must wait for
# the first and then be refused, the way a write waits for a settlement
# (spec/db/settlement_race_spec.rb).
#
# The cost here is raw SQL on a libpq session of its own, the way psql
# writes: no model, no lock of its own, at READ COMMITTED. The cancel is
# raw SQL the same way, or the app's own cancel: the meal row locked FOR
# UPDATE and Meal#cancel! under it, retried on a conflict, as
# MealStatusActions (PATCH /meals/:id/cancelled) and the admin Cancel
# button do it.
RSpec.describe 'cancelling a dinner, against a cost with money entered at the same moment from raw SQL' do
  include_context 'with no test transaction'

  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:meal) { create(:meal, community: community, date: Reconciliation.latest_cutoff(community.today)) }
  let(:cook) { create(:resident, community: community, unit: unit) }
  # A blank cost: $0 and not No cost. Cancelling the dinner is allowed now.
  let!(:bill) { create(:bill, meal: meal, resident: cook, community: community, amount: 0) }

  before do
    create(:meal_resident, meal: meal, resident: create(:resident, community: community, unit: unit),
                           community: community)
  end

  def open_session
    db = ActiveRecord::Base.connection_db_config.configuration_hash
    PG.connect(host: db[:host], port: db[:port], user: db[:username], password: db[:password], dbname: db[:database])
  end

  def cost_sql = "UPDATE bills SET amount = 12 WHERE id = #{bill.id}"
  def cancel_sql = "UPDATE meals SET cancelled_at = now() WHERE id = #{meal.id}"

  # Runs `sql` on a session of its own, in a thread. The thread's value
  # is :written, or the first line of the database's refusal.
  def raw_write_alone(sql)
    Thread.new do
      Thread.current.report_on_exception = false
      session = open_session
      session.exec("SET statement_timeout = '10s'")
      session.exec(sql)
      :written
    rescue PG::Error => e
      e.message.lines.first.strip
    ensure
      session&.close
    end
  end

  # The app's own cancel, in a thread, on a Rails connection of its own
  # (SERIALIZABLE, like every Rails session). The thread's value is
  # :written, or the error.
  def app_cancel_alone
    Thread.new do
      Thread.current.report_on_exception = false
      ActiveRecord::Base.connection_pool.with_connection do
        dinner = Meal.find(meal.id)
        RetryOnConflict.call do
          dinner.restore_attributes
          dinner.with_lock { dinner.cancel! }
        end
        :written
      end
    rescue StandardError => e
      "#{e.class}: #{e.message.lines.first&.strip}"
    end
  end

  # Waits until the thread has finished, or a session waits for a lock.
  def finished_or_waiting(thread, observer)
    200.times do
      return :finished unless thread.alive?

      waiting = observer.exec(
        'SELECT count(*) FROM pg_stat_activity WHERE datname = current_database() ' \
        "AND pid <> pg_backend_pid() AND wait_event_type = 'Lock'"
      ).getvalue(0, 0).to_i.positive?
      return :waited if waiting

      sleep 0.02
    end
    :neither
  end

  def money_on_a_cancelled_dinner?
    Meal.where(id: meal.id).where.not(cancelled_at: nil).exists? &&
      Bill.where(meal_id: meal.id, no_cost: false).where('amount > 0').exists?
  end

  # Runs `first_sql` in a transaction on one session, starts the second
  # write while the first is still open, then commits the first. Returns
  # how the second write ended, and whether it waited.
  def race(first_sql)
    observer = open_session
    first = open_session
    first.exec('BEGIN')
    first.exec(first_sql)
    second = yield
    seen = finished_or_waiting(second, observer)
    first.exec('COMMIT')
    [second.value, seen]
  ensure
    first&.close
    observer&.close
  end

  def failure(write, outcome, seen)
    "the #{write} #{seen} and ended #{outcome.inspect}: the dinner is cancelled, and its cook is credited $0 " \
      'for the $12 they spent'
  end

  it 'refuses a raw cancel that comes while a raw cost with money on it is being saved' do
    outcome, seen = race(cost_sql) { raw_write_alone(cancel_sql) }

    expect(money_on_a_cancelled_dinner?).to be(false), failure('cancel', outcome, seen)
  end

  it 'refuses a raw cost with money on it that comes while the dinner is being cancelled from raw SQL' do
    outcome, seen = race(cancel_sql) { raw_write_alone(cost_sql) }

    expect(money_on_a_cancelled_dinner?).to be(false), failure('cost', outcome, seen)
  end

  # The app's cancel takes the meal lock first, so it waits for the raw
  # cost's FOR KEY SHARE. But at SERIALIZABLE its snapshot is taken when
  # that first statement starts, before the wait, so after the wait it
  # still reads the bill at $0. The raw cost ran at READ COMMITTED, so
  # PostgreSQL's conflict check does not see it, and the lock it held
  # changed no row, so the wait ends without a conflict either.
  it "refuses the app's own cancel when it comes while a raw cost with money on it is being saved" do
    outcome, seen = race(cost_sql) { app_cancel_alone }

    expect(money_on_a_cancelled_dinner?).to be(false), failure('cancel', outcome, seen)
  end
end
