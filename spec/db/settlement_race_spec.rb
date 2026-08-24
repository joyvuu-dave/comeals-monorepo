# frozen_string_literal: true

require 'rails_helper'

# Pins issue #43: a write from a path that does not take the meal lock must not
# be able to change a meal's ledger rows while `reconciliations:create` is
# claiming it — in either direction, adding or removing.
#
# Before the fix such a write committed onto a meal that was reconciled by the
# time it landed, and the reconciliation's stored balances stopped matching
# their own source data. Adding a row meant it was in no reconciliation's
# balances, and billing:recalculate skipped it because that task only sums
# unreconciled meals, so a cook was never reimbursed. Removing one meant a
# stored balance computed from a row that no longer exists. Nothing raised in
# either case — allocate_to_cents still summed to zero, because it summed
# whatever was in front of it.
#
# Closing it took three things, and each was tested alone and fails:
#
#   1. Settlement#assign_meals takes FOR UPDATE before claiming, so a rival
#      write's FOR KEY SHARE on the parent meal has something to wait on. Its
#      UPDATE alone takes only FOR NO KEY UPDATE, which FOR KEY SHARE does not
#      conflict with — there would be no wait at all.
#   2. The trigger's NEW.meal_id lookup is an unconditional FOR KEY SHARE read
#      (20260727120000), so an INSERT decides after that wait against committed
#      state. Without it the trigger decides first — Postgres fires BEFORE
#      INSERT triggers before the foreign-key check — and the insert proceeds
#      once the FK wait ends.
#   3. The trigger's OLD.meal_id lookup locks the same way, so a DELETE or a
#      re-parent waits too. A DELETE takes no foreign-key lock on the parent at
#      all, so this lookup is the only thing that can stop it.
#
# See docs/adr/0003-concurrency-on-the-money-path.md.
RSpec.describe 'settlement race against unlocked write paths' do
  # These examples need a second session's statement to be genuinely in
  # flight while the settlement transaction is still open. Transactional
  # fixtures would hide every commit inside one never-committed transaction,
  # so this file writes real rows; the shared context below cleans them up
  # (spec/support/non_transactional_cleanup.rb).
  include_context 'with no test transaction'

  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:cook) { create(:resident, community: community, unit: unit, multiplier: 2) }
  let(:eater) { create(:resident, community: community, unit: unit, multiplier: 2) }
  let(:latecomer) { create(:resident, community: community, unit: unit, multiplier: 2) }
  let(:meal) { create(:meal, community: community) }

  # A second meal with no bills. eligible_meal_ids joins bills, so this one is
  # never swept and never locked — it is the destination for the "move a row
  # off the settling meal" case.
  let(:other_meal) { create(:meal, community: community) }

  # Rows that already exist on the meal, so the racing DELETE and UPDATE cases
  # have something to aim at without opening another session first.
  let(:doomed_bill) { create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('50')) }
  let(:doomed_attendance) { create(:meal_resident, meal: meal, resident: eater, community: community, multiplier: 2) }
  let(:doomed_guest) { create(:guest, meal: meal, resident: eater, multiplier: 1) }

  before do
    doomed_bill
    doomed_attendance
    doomed_guest
    latecomer # created up front so the racing INSERT needs no extra session
    other_meal
  end

  # A raw libpq connection, not a second ActiveRecord checkout. libpq's async
  # API is what makes "is this statement blocked right now?" observable from
  # the same thread — no sleeps, no threads, no flake.
  def open_session
    db = ActiveRecord::Base.connection_db_config.configuration_hash
    PG.connect(host: db[:host], port: db[:port], user: db[:username],
               password: db[:password], dbname: db[:database])
  end

  def with_sessions
    writer = open_session
    observer = open_session
    yield writer, observer
  ensure
    writer&.close
    observer&.close
  end

  # :done once the in-flight statement has its result waiting, :blocked once
  # Postgres reports that session waiting on a lock. Polled rather than slept
  # on — a fixed sleep would be either slow or flaky.
  def statement_state(writer, observer)
    200.times do
      writer.consume_input
      return :done unless writer.is_busy

      waiting = observer.exec_params(
        "SELECT count(*) FROM pg_stat_activity WHERE pid = $1 AND wait_event_type = 'Lock'",
        [writer.backend_pid]
      ).getvalue(0, 0).to_i
      return :blocked if waiting.positive?

      sleep 0.02
    end
    :timeout
  end

  # Runs a real settlement and yields inside it, once assign_meals has claimed
  # the meals and the given query has run, with the settlement transaction
  # still open.
  #
  # Which query to wait for matters. 'Meal Update All' is the claim itself —
  # use it to start something that must see the meals as still unreconciled.
  # 'Guest Load' is the last of settlement_ledger's three child-row preloads
  # (bills, then attendance, then guests). It is the latest point a racing
  # write can start and still be missed by the balances, so it is the hardest
  # version of the test: anything that starts earlier only has longer to wait.
  #
  # (Since assign_meals holds FOR UPDATE for the whole transaction, a racing
  # write cannot actually commit anywhere between the claim and these reads —
  # it blocks. That is the fix working. Before it, a write in this window
  # committed and vanished from the ledger.)
  def settle_yielding_after(query_name)
    claimed = false
    fired = false

    subscriber = ActiveSupport::Notifications.subscribe('sql.active_record') do |event|
      claimed = true if event.payload[:name] == 'Meal Update All'
      next if fired || !claimed || event.payload[:name] != query_name

      fired = true
      yield
    end

    begin
      reconciliation = create(:reconciliation, community: community)
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    raise "the settlement never ran #{query_name} after claiming its meals" unless fired

    reconciliation
  end

  # What the reconciliation stored, against what its source data says now.
  # These must match: a child row that landed during the claiming window is
  # in the source data but not in the stored balances, and no later check
  # ever notices.
  def stored_balances(reconciliation)
    reconciliation.reconciliation_balances.pluck(:resident_id, :amount).to_h
  end

  def balances_from_source(reconciliation)
    reconciliation.settlement_balances.reject { |_, amount| amount.zero? }
  end

  def racing_write_error(writer)
    writer.get_last_result
    nil
  rescue PG::Error => e
    e
  end

  # Fires `sql` on a second session while the settlement holds its claim, then
  # asserts the outcome in the order that matters. First the money: the
  # settled ledger must still match its source data, which is the thing that
  # silently broke. Then the mechanism — the trigger refused the write (part
  # 2 decided after the wait), and the write really did wait (part 1 gave it
  # something to wait on).
  def expect_racing_write_refused(sql, params)
    with_sessions do |writer, observer|
      state = nil

      reconciliation = settle_yielding_after('Guest Load') do
        writer.send_query_params(sql, params)
        state = statement_state(writer, observer)
      end
      error = racing_write_error(writer)

      expect(stored_balances(reconciliation)).to eq(balances_from_source(reconciliation))
      expect(error).to be_a(PG::RaiseException)
      expect(error.message).to include('reconciled')
      expect(state).to eq(:blocked)
    end
  end

  describe 'a write that races the claiming UPDATE' do
    it 'refuses an admin-style bill insert' do
      expect_racing_write_refused(
        'INSERT INTO bills (meal_id, resident_id, community_id, amount, no_cost, created_at, updated_at) ' \
        'VALUES ($1, $2, $3, $4, false, now(), now())',
        [meal.id, latecomer.id, community.id, '25']
      )
    end

    it 'refuses an admin-style attendance insert' do
      expect_racing_write_refused(
        'INSERT INTO meal_residents (meal_id, resident_id, community_id, multiplier, ' \
        'late, vegetarian, created_at, updated_at) ' \
        'VALUES ($1, $2, $3, $4, false, false, now(), now())',
        [meal.id, latecomer.id, community.id, 2]
      )
    end

    it 'refuses an admin-style guest insert' do
      expect_racing_write_refused(
        'INSERT INTO guests (meal_id, resident_id, multiplier, late, vegetarian, created_at, updated_at) ' \
        'VALUES ($1, $2, $3, false, false, now(), now())',
        [meal.id, latecomer.id, 2]
      )
    end
  end

  # The mirror of the block above (issue #43), and the half that is easiest to
  # talk yourself out of locking. A DELETE takes no foreign-key lock on the
  # parent meal — there is nothing to check on the way out — so unless the
  # trigger's OLD.meal_id lookup locks, these go straight through with no wait
  # and no error. That was measured, not assumed. The reconciliation then stored
  # a balance computed from a row that no longer existed: a cook credited for a
  # deleted bill, a resident charged with no attendance row to show for it.
  #
  # Both admin paths that reach this are real buttons, not just psql:
  # app/admin/meal_resident.rb exposes destroy (issue #25's attendance
  # corrections) and app/admin/bill.rb allows destroy.
  describe 'a write that deletes a child row while the settlement claims it' do
    it 'refuses an admin-style bill delete' do
      expect_racing_write_refused('DELETE FROM bills WHERE id = $1', [doomed_bill.id])
    end

    it 'refuses an admin-style attendance delete' do
      expect_racing_write_refused('DELETE FROM meal_residents WHERE id = $1', [doomed_attendance.id])
    end

    it 'refuses an admin-style guest delete' do
      expect_racing_write_refused('DELETE FROM guests WHERE id = $1', [doomed_guest.id])
    end

    # app/admin/bill.rb permits :meal_id, so the form can move a bill between
    # meals. Moving one OFF the settling meal removes it from the ledger just
    # as a delete would, and it is the OLD.meal_id lookup that has to catch it —
    # the NEW lookup only sees the unlocked destination.
    it 'refuses moving a bill off the meal being settled' do
      expect_racing_write_refused(
        'UPDATE bills SET meal_id = $1 WHERE id = $2',
        [other_meal.id, doomed_bill.id]
      )
    end
  end

  describe 'the API path (control)' do
    # with_meal_lock takes FOR UPDATE and then inserts a child row in the same
    # transaction. The trigger's new FOR KEY SHARE lookup hits a row this same
    # transaction already holds FOR UPDATE, which is a self-lock and never
    # waits. If that were wrong, every attendance write in the app would hang.
    it 'still writes a child row inside its own meal lock' do
      expect do
        meal.with_lock do
          MealResident.create!(meal: meal, resident: latecomer, community: community, multiplier: 2)
        end
      end.to change { meal.meal_residents.count }.by(1)
    end

    # Same self-lock argument for the DELETE branch's lookup. Leaving the meal
    # is the ordinary "I'm not coming to dinner" path, so if this ever waits,
    # every un-RSVP in the app hangs.
    it 'still deletes a child row inside its own meal lock' do
      expect do
        meal.with_lock { doomed_attendance.destroy! }
      end.to change { meal.meal_residents.count }.by(-1)
    end
  end

  describe 'two settlements racing each other' do
    # Waits for some other backend to be blocked on a lock while running a
    # statement that looks like `sql_fragment`.
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

    # Only one of the two settlements may survive, and it must own every
    # swept meal. That is the money-level guarantee, and it holds at both
    # isolation levels — but which side dies, and how, does not:
    #
    #   READ COMMITTED  the rival blocks on FOR UPDATE, wakes once this
    #                   settlement commits, plucks meals that are now
    #                   claimed, and its compare-and-swap in assign_meals
    #                   raises.
    #   SERIALIZABLE    SSI cancels *this* settlement first, at the bills
    #                   read inside write_ledger!, for a read/write
    #                   dependency with the blocked rival ("canceled on
    #                   identification as a pivot"). This settlement rolls
    #                   back, the rival wakes to unclaimed meals, and the
    #                   rival is the one that survives.
    #
    # So the roles swap. These assertions are on the outcome rather than on
    # which side raises, because the outcome is what the ledger cares about
    # and it is the same either way.
    it 'lets exactly one of two racing settlements survive, owning every meal' do
      with_sessions do |_writer, observer|
        rival = nil
        blocked = false

        main_error = begin
          settle_yielding_after('Meal Update All') do
            rival = Thread.new do
              # One of the two is expected to raise. Without this Ruby also
              # prints its backtrace to stderr.
              Thread.current.report_on_exception = false
              ActiveRecord::Base.connection_pool.with_connection { create(:reconciliation, community: community) }
            end
            # The rival plucks its eligible meals before it locks, so it must
            # reach the lock while this settlement is still uncommitted —
            # otherwise it would see the claim and pluck nothing, and there
            # would be no race left to test.
            blocked = wait_for_blocked_session(observer, 'FOR UPDATE')
          end
          nil
        rescue StandardError => e
          e
        end

        rival_error = begin
          rival.value
          nil
        rescue StandardError => e
          e
        end

        expect(blocked).to be(true)
        # Exactly one side lost. Not both, which would settle nothing, and
        # not neither, which would settle the same meals twice.
        expect([main_error, rival_error].compact.size).to eq(1)

        survivor = Reconciliation.sole
        expect(meal.reload.reconciliation_id).to eq(survivor.id)
        # The ledger the survivor stored still matches its own source data.
        expect(stored_balances(survivor)).to eq(balances_from_source(survivor))
      end
    end

    # What re-running buys on the path that actually loses at SERIALIZABLE.
    # A settlement cancelled as a pivot is not broken and nothing about it
    # needs fixing; the documented response is to run it again.
    #
    # Note what does *not* happen here, because it is easy to write this
    # test believing it does: RetryOnConflict never retries inside this
    # example. The rival has committed by the time the settlement runs
    # again, so `must_settle_at_least_one_meal` refuses the very first
    # attempt and there is no conflict left to retry. Measured — the
    # reported-error list came back empty every run. The retry loop itself
    # is proved in spec/services/retry_on_conflict_spec.rb.
    #
    # What this example proves is the pairing: after a real SSI
    # cancellation, running the settlement again is safe and lands on a
    # refusal that names a domain rule. Without that second run the task
    # dies on a raw PG::TRSerializationFailure, which tells a human nothing
    # they can act on. With it the task says there was nothing left to
    # settle, which is true and actionable.
    #
    # This uses Reconciliation.create! directly rather than the factory. The
    # factory's before(:create) hook builds a unit, a cook, a meal and a bill
    # for itself, so retrying it manufactures fresh work: the second attempt
    # succeeds on a meal that did not exist when the race started, and two
    # reconciliations result. A retried block has to be safe to run twice,
    # and the factory is not. Measured, not reasoned about — that is exactly
    # what happened on the first attempt at this test.
    it 'can safely re-run a cancelled settlement, which is then refused for having nothing to settle' do
      with_sessions do |_writer, observer|
        rival = nil

        main_error = begin
          settle_yielding_after('Meal Update All') do
            rival = Thread.new do
              Thread.current.report_on_exception = false
              ActiveRecord::Base.connection_pool.with_connection { create(:reconciliation, community: community) }
            end
            wait_for_blocked_session(observer, 'FOR UPDATE')
          end
          nil
        rescue StandardError => e
          e
        end
        rival.join

        # At READ COMMITTED the rival is the side that loses, so there is no
        # cancelled settlement to retry and nothing here to prove.
        skip 'this run cancelled the rival, not the settlement' if main_error.nil?

        retried = begin
          RetryOnConflict.call do
            settle!(community, cutoff: Date.yesterday)
          end
        rescue ActiveRecord::RecordInvalid => e
          e
        end

        expect(retried).to be_a(ActiveRecord::RecordInvalid)
        expect(retried.message).to match(/must settle at least one meal/i)
        # Still exactly one settlement, still owning the meals.
        expect(Reconciliation.count).to eq(1)
        expect(meal.reload.reconciliation_id).to eq(Reconciliation.sole.id)
      end
    end
  end
end
