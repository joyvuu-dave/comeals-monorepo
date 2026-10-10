# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('spec/support/oracle/plain_ledger')

# Several threads write to one meal at once, the way several phones do at
# dinner time, while another thread settles it. The settlement is the real
# one (SettleAndNotify), with short retries.
#
# Two phases. In the first the writers and the settler run together. Each
# writer takes the meal row lock and re-checks the settlement under it,
# exactly as Api::V1::MealsController#with_meal_lock does, and retries a
# serialization failure the same way (RetryOnConflict). The settler tries
# until it wins. Once the writers have done their rounds, one of them makes
# sure the meal can be settled, and they all wait for the settler and then
# write a few times more, so every run has writes on both sides of the
# settlement. The second phase sends the same kinds of writes to the
# settled meal, but the writers no longer check the settlement themselves,
# and half of them take no meal lock, the way admin writes: the models must
# refuse every write, and nothing may change.
#
# What must hold at the end:
#   - every action ended in one of the outcomes the API knows how to
#     answer: written, refused by a rule, refused because settled, nothing
#     to do, or a conflict; never another exception, never a lock timeout;
#   - the storm finished (no deadlock);
#   - the settler settled the meal in phase 1, and phase 1 writes then met
#     the settled meal;
#   - the rows are sound and the ledger over them agrees with the plain
#     ledger and sums to zero;
#   - the stored charges equal the ledger over the final rows, which is
#     only true if no write got through after the settlement;
#   - in phase 2 no write went through, the models refused some, and the
#     rows are the rows right after the settlement;
#   - ledger:verify passes.
#
# spec/db/settlement_race_spec.rb pins one interleaving exactly, with two
# raw sessions. This runs thousands of interleavings loosely, and reports
# the seed of any that breaks.
RSpec.describe 'a write storm against one meal, with a settlement in it' do
  include_context 'with no test transaction'

  # Five threads need five connections. The pool is two (config/database.yml
  # explains why); this group opens a wider one and puts the old one back.
  before(:all) do
    # rubocop:disable RSpec/InstanceVariable -- before(:all) has no let; the pool is process state
    @original_db_config = ActiveRecord::Base.connection_db_config.configuration_hash
    ActiveRecord::Base.establish_connection(@original_db_config.merge(pool: 8))
  end

  after(:all) do
    ActiveRecord::Base.establish_connection(@original_db_config)
    # rubocop:enable RSpec/InstanceVariable
  end

  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:residents) do
    [2, 2, 2, 1, 0, 2].map { |m| create(:resident, community: community, unit: unit, multiplier: m) }
  end
  let(:meal) { create(:meal, community: community, date: Date.yesterday) }

  # --- one write -------------------------------------------------------------

  # How a write reaches the meal. :api is the way the API writes
  # (Api::V1::MealsController#with_meal_lock): the meal row lock, then a
  # settled meal is refused before anything is written. :unchecked takes
  # the lock but leaves the settled check to the models. :unlocked takes
  # no lock and checks nothing itself, the way admin writes through the
  # models. Phase 2 uses the last two, so that the app, not this helper,
  # has to refuse each write.
  #
  # Returns the outcome. The block gets the meal and returns the record it
  # wrote or tried to write, true (several rows written, see write_bills)
  # or nil (nothing to do).
  def meal_write(meal_id, how)
    RetryOnConflict.call do
      Meal.transaction do
        meal = how == :unlocked ? Meal.find(meal_id) : Meal.lock.find(meal_id)
        next :refused_settled if how == :api && meal.reconciled?

        outcome_of(yield(meal))
      end
    end
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotDestroyed => e
    settled_refusal?(e.record) ? :refused_settled : [:error, "#{e.class}: #{e.message}"]
  rescue ActiveRecord::TransactionRollbackError
    :conflict
  rescue ActiveRecord::LockWaitTimeout
    :lock_timeout
  rescue ActiveRecord::StatementInvalid => e
    return :refused_by_trigger if e.message.include?('is reconciled and its ledger rows are immutable')

    [:error, "#{e.class}: #{e.message}"]
  rescue StandardError => e
    [:error, "#{e.class}: #{e.message}"]
  end

  def outcome_of(result)
    case result
    when nil then :noop
    when true then :ok
    else
      return :ok if result.errors.empty?

      settled_refusal?(result) ? :refused_settled : :refused
    end
  end

  def settled_refusal?(record) = record.errors[:base].include?(ReconciledMealImmutability::MESSAGE)

  # The row after its destroy (its errors say why, when a guard refused),
  # or nil when there was none.
  def destroyed(row) = row&.tap(&:destroy)

  def write(meal_id, action, rng, how = :api)
    case action
    when :set_bills then write_bills(meal_id, rng, how)
    when :close then meal_write(meal_id, how) { |meal| meal.tap { |m| m.update(closed: true) } }
    when :reopen then meal_write(meal_id, how) { |meal| meal.tap { |m| m.update(closed: false) } }
    else write_person(meal_id, action, residents.sample(random: rng), rng, how)
    end
  end

  def write_person(meal_id, action, resident, rng, how)
    case action
    when :signup
      meal_write(meal_id, how) do |meal|
        row = meal.meal_residents.find_or_initialize_by(resident_id: resident.id)
        row.late = rng.rand < 0.3
        row.tap(&:save)
      end
    when :leave
      meal_write(meal_id, how) { |meal| destroyed(meal.meal_residents.find_by(resident_id: resident.id)) }
    when :add_guest
      meal_write(meal_id, how) do |meal|
        Guest.new(meal_id: meal.id, resident_id: resident.id, vegetarian: false).tap(&:save)
      end
    when :remove_guest
      meal_write(meal_id, how) { |meal| destroyed(meal.guests.order(:id).first) }
    end
  end

  # Bill rows written through the models: the cooks not picked are
  # removed and the picked ones are written. An API save
  # (BillsPayload#write_to) makes the same row writes when its edits
  # remove some cooks and add or change the rest. This spec is about the
  # rows and the locks, not about what the page saw.
  def write_bills(meal_id, rng, how)
    cooks = residents.sample(rng.rand(1..3), random: rng)
    amounts = cooks.to_h { |c| [c.id, BigDecimal(rng.rand(0..999_999)) / 100] }
    meal_write(meal_id, how) do |meal|
      meal.bills.where.not(resident_id: cooks.map(&:id)).find_each(&:destroy!)
      amounts.each do |id, amount|
        meal.bills.find_or_initialize_by(resident_id: id).update!(amount: amount, no_cost: false)
      end
      true
    end
  end

  def actions = %i[signup signup signup leave leave add_guest remove_guest set_bills set_bills close reopen]

  # Phase 2 leaves out close and reopen: `closed` is not settled data, so
  # a settled meal may still be closed or reopened.
  def settled_actions = actions - %i[close reopen]

  # --- the storm --------------------------------------------------------------

  # Four writer threads, each with its own seeded dice and its own
  # connection.
  def writer_threads(seed)
    Array.new(4) do |t|
      Thread.new do
        Thread.current.report_on_exception = false
        rng = Random.new((seed * 100) + t)
        ActiveRecord::Base.connection_pool.with_connection { yield t, rng }
      end
    end
  end

  # Phase 1. Each writer writes `rounds` times, the way the API does, while
  # the settler tries to settle. Then it waits for the settler to finish
  # and writes writes_after_settler times more, so every run has writes on
  # both sides of the settlement. It waits without writing: a writer that
  # kept writing could make the settler lose try after try.
  #
  # Before that wait, once every writer has done its rounds, the first
  # writer reopens the meal and signs someone up. A closed meal refuses a
  # sign-up, and a meal with a receipt and nobody who ate is held back
  # from settlement, so without this the storm could end with a meal no
  # settlement may take, and the settler would give up.
  def run_writers(meal_id, seed, rounds, log, settler)
    rounds_done = Concurrent::AtomicFixnum.new(0)
    writer_threads(seed) do |t, rng|
      rounds.times { |i| log << write_once(meal_id, [t, i], actions.sample(random: rng), rng) }
      rounds_done.increment
      if t.zero?
        sleep(0.005) until rounds_done.value == 4
        log << write_once(meal_id, [t, rounds], :reopen, rng)
        log << write_once(meal_id, [t, rounds + 1], :signup, rng)
      end
      sleep(0.005) while settler.alive?
      writes_after_settler.times do |i|
        log << write_once(meal_id, [t, rounds + 2 + i], actions.sample(random: rng), rng)
      end
    end
  end

  def writes_after_settler = 3

  # Phase 2, against the settled meal. Half the writers take the meal lock
  # and half do not, and none checks the settlement itself, so each write
  # has to be refused by the models (or by the triggers behind them).
  def run_settled_writers(meal_id, seed, rounds, log)
    writer_threads(seed) do |t, rng|
      how = t.even? ? :unchecked : :unlocked
      rounds.times { |i| log << write_once(meal_id, [t, i], settled_actions.sample(random: rng), rng, how) }
    end
  end

  def write_once(meal_id, (thread, index), action, rng, how = :api)
    entry = [thread, index, action, write(meal_id, action, rng, how)]
    sleep(rng.rand * 0.002)
    entry
  end

  # The real entry point, with the nightly task's ten tries
  # (SettleAndNotify::BATCH) but shorter waits between them. BATCH waits
  # from a quarter second up, which is longer than the writers' rounds
  # take, so with it the settlement always landed after the last write and
  # phase 1 never raced it. The waits are SettleAndNotify's own spec's job;
  # the number of tries is checked here: giving up is not rescued, so it
  # is an :error outcome, and the storm asserts there are none.
  def storm_retries = SettleAndNotify::Retries.new(attempts: SettleAndNotify::BATCH.attempts, base_delay: 0.01)

  def run_settler(seed, log)
    Thread.new do
      Thread.current.report_on_exception = false
      rng = Random.new(seed)
      ActiveRecord::Base.connection_pool.with_connection do
        # Not before the writers have done a good part of their work, so
        # phase 1 always has writes on both sides of the settlement.
        sleep(0.005) until log.size >= 40 + rng.rand(20)
        # Up to 200 settlements, about five seconds: the writers make the
        # meal settleable at the latest once their rounds are done (see
        # run_writers). Until then a settlement may be refused for having
        # nothing to settle, or contested, and is tried again.
        200.times do
          settlement = SettleAndNotify.call(cutoff: Date.yesterday, retries: storm_retries)
          log << [:settler, 0, :settle, [:settled, settlement.reconciliation.id]]
          break
        rescue ActiveRecord::RecordInvalid, Settlement::Contested
          sleep(0.02)
        rescue StandardError => e
          log << [:settler, 0, :settle, [:error, "#{e.class}: #{e.message}"]]
          break
        end
      end
    end
  end

  def join_all(threads, label)
    threads.each do |thread|
      expect(thread.join(60)).not_to be_nil, "#{label}: a thread did not finish in 60 seconds (deadlock?)"
    end
  end

  # --- the checks -------------------------------------------------------------

  def snapshot(meal_id)
    rows = Meal.preload(:bills, :meal_residents, :guests).find(meal_id)
    { attendance: rows.meal_residents.map { |a| [a.resident_id, a.late] }.sort,
      guests: rows.guests.map { |g| [g.id, g.resident_id] }.sort,
      bills: rows.bills.map { |b| [b.resident_id, b.amount, b.no_cost] }.sort,
      closed: rows.closed, reconciled: rows.reconciled? }
  end

  def expect_outcomes_clean(log, label)
    fine = %i[ok refused refused_settled refused_by_trigger noop conflict]
    bad = log.reject do |_, _, _, outcome|
      fine.include?(outcome) || (outcome.is_a?(Array) && outcome.first == :settled)
    end
    expect(bad).to be_empty, "#{label}: unexpected outcomes #{bad.inspect}"
  end

  def expect_close(actual, expected, label)
    (actual.keys | expected.keys).each do |id|
      a = actual.fetch(id, BigDecimal('0'))
      e = expected.fetch(id, BigDecimal('0'))
      expect(a).to eq(e), "#{label} for resident #{id}: #{a.to_s('F')} vs #{e.to_s('F')}"
    end
  end

  def expect_ledger_sound(meal_id, label)
    rows = Meal.preload(:bills, :meal_residents, :guests).find(meal_id)
    lines = MealLedger.new([rows]).lines
    expect(lines.sum(BigDecimal('0'), &:amount)).to eq(0), "#{label}: lines do not sum to zero"
    net = lines.group_by(&:resident_id).transform_values { |l| l.sum(BigDecimal('0'), &:amount) }
    expect_close(net, PlainLedger.net_by_meal([RandomLedger.plain(rows)]).transform_keys(&:last),
                 "#{label}: ledger and oracle differ")
    return unless rows.reconciled?

    # Only true if no write got through after the settlement.
    expect_close(MealCharge.where(meal_id: meal_id).group(:resident_id).sum(:amount), net,
                 "#{label}: stored charges differ from the final rows")
    balances = ReconciliationBalance.where(reconciliation_id: rows.reconciliation_id).sum(:amount)
    expect(balances).to eq(0), "#{label}: settled balances sum to #{balances}"
    expect(LedgerVerification.call).to be_passed, "#{label}: ledger:verify fails"
  end

  (1..5).each do |seed|
    it "survives storm #{seed}" do
      residents
      meal_id = meal.id
      log = Queue.new

      settler = run_settler(seed, log)
      writers = run_writers(meal_id, seed, 25, log, settler)
      join_all(writers + [settler], "storm #{seed}, phase 1")
      first = Array.new(log.size) { log.pop }
      expect_outcomes_clean(first, "storm #{seed}, phase 1")
      expect_ledger_sound(meal_id, "storm #{seed}, phase 1")
      # The settler settled the meal while the writers were at it, and
      # writes then met the settled meal. A run where the settler never
      # won, or won after the last write, fails here.
      settled_by = first.select { |thread, *| thread == :settler }.map(&:last)
      expect(settled_by).to eq([[:settled, Meal.find(meal_id).reconciliation_id]]),
                            "storm #{seed}, phase 1: the settler did not settle the meal: #{settled_by}"
      after_settlement = first.count { |*, outcome| outcome == :refused_settled }
      expect(after_settlement).to be >= 4 * writes_after_settler,
                                  "storm #{seed}, phase 1: only #{after_settlement} writes met the settled meal"

      expect(Meal.find(meal_id)).to be_reconciled
      settled_rows = snapshot(meal_id)

      writers = run_settled_writers(meal_id, seed + 1000, 10, log)
      join_all(writers, "storm #{seed}, phase 2")
      second = Array.new(log.size) { log.pop }
      expect_outcomes_clean(second, "storm #{seed}, phase 2")
      # Refused by the models (or the triggers), nothing to do (a leave for
      # someone not signed up, a guest removal with no guests), or a
      # conflict after the retries, which writes nothing either. Never
      # written.
      outcomes = second.map(&:last)
      unwritten = %i[refused_settled refused_by_trigger noop conflict]
      expect(outcomes - unwritten).to be_empty, "storm #{seed}, phase 2: #{outcomes.tally}"
      expect(outcomes).to include(:refused_settled)
      expect(snapshot(meal_id)).to eq(settled_rows), "storm #{seed}, phase 2: the settled rows changed"
      expect_ledger_sound(meal_id, "storm #{seed}, phase 2")
      tally = first.map(&:last).map { |o| o.is_a?(Array) ? o.first : o }.tally
      RSpec.configuration.reporter.message("storm #{seed}: #{tally}") if ENV['STORM_TALLY']
      expect(tally.fetch(:ok, 0)).to be >= 10, "storm #{seed}: only #{tally[:ok]} writes went through: #{tally}"
    end
  end
end
