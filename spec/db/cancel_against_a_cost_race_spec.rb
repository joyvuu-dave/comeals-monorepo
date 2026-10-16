# frozen_string_literal: true

require 'rails_helper'

# A dinner a cook spent money on cannot be cancelled (ADR 0011 rule 11).
# The database holds that rule too, for a write that skips the model
# (20261010125954):
#
#   - comeals_protect_settled_meal refuses a cancel when a bill of the
#     dinner has money on it;
#   - comeals_reject_settled_child_write refuses a cost on a cancelled
#     dinner.
#
# Each rule reads the other writer's row, so a cost and a cancel at the
# same moment must not both go through: whichever comes second must wait
# for the first, and then be refused.
#
# The cost here is raw SQL on a libpq session of its own, the way psql
# writes: no model, no lock of its own, at READ COMMITTED. Until
# 20261016120000 both orders went wrong. The trigger read the meal row
# FOR KEY SHARE, which a cancel's UPDATE (FOR NO KEY UPDATE) does not wait
# for. The app's cancel did wait, at its FOR UPDATE, but it runs at
# SERIALIZABLE: its snapshot was taken before the wait, a lock changes no
# row, and PostgreSQL's conflict check does not see a READ COMMITTED
# writer, so after the wait it still read the cost as $0. Each time the
# dinner ended cancelled with $12 on a cost, and the cook was credited $0
# for it.
#
# Now the trigger updates the meal row (updated_at = updated_at). A raw
# cancel waits for that update and then reads the cost; a raw cost waits
# for a raw cancel and then reads the cancel; and an app cancel that
# waited finds the meal row changed, fails as a conflict, and is tried
# again with a fresh snapshot (or, from the console with no retry, fails).
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

  # A Rails write, in a thread, on a Rails connection of its own
  # (SERIALIZABLE, like every Rails session). The thread's value is
  # :written, or the error's class and first line.
  def app_write_alone
    Thread.new do
      Thread.current.report_on_exception = false
      ActiveRecord::Base.connection_pool.with_connection do
        yield Meal.find(meal.id)
        :written
      end
    rescue StandardError => e
      "#{e.class}: #{e.message.lines.first&.strip}"
    end
  end

  # The app's own cancel: the meal row locked FOR UPDATE, Meal#cancel!
  # under it, retried on a conflict, as MealStatusActions (PATCH
  # /meals/:id/cancelled) and the admin Cancel button run it.
  def app_cancel_alone
    app_write_alone do |dinner|
      RetryOnConflict.call do
        dinner.restore_attributes
        dinner.with_lock { dinner.cancel! }
      end
    end
  end

  # Meal#cancel! as someone would call it from the console: no meal lock
  # and no retry.
  def console_cancel_alone
    app_write_alone(&:cancel!)
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
    expect(seen).to eq(:waited)
    expect(outcome).to include('has a cost with money on it, so it cannot be cancelled')
  end

  it 'refuses a raw cost with money on it that comes while the dinner is being cancelled from raw SQL' do
    outcome, seen = race(cancel_sql) { raw_write_alone(cost_sql) }

    expect(money_on_a_cancelled_dinner?).to be(false), failure('cost', outcome, seen)
    expect(seen).to eq(:waited)
    expect(outcome).to include("meal #{meal.id} is cancelled")
  end

  it "refuses the app's own cancel when it comes while a raw cost with money on it is being saved" do
    outcome, seen = race(cost_sql) { app_cancel_alone }

    expect(money_on_a_cancelled_dinner?).to be(false), failure('cancel', outcome, seen)
    expect(seen).to eq(:waited)
    # The first try failed as a conflict; the second read the cost.
    expect(outcome).to eq('ActiveRecord::RecordInvalid: Validation failed: ' \
                          "A cook spent money on this dinner, so it can't be cancelled.")
  end

  it 'refuses Meal#cancel! from the console when it comes while a raw cost with money on it is being saved' do
    outcome, seen = race(cost_sql) { console_cancel_alone }

    expect(money_on_a_cancelled_dinner?).to be(false), failure('cancel', outcome, seen)
    expect(seen).to eq(:waited)
    # Nothing retries a console call, so the conflict is the answer.
    expect(outcome).to start_with('ActiveRecord::SerializationFailure')
  end
end
