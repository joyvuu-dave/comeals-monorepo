# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('spec/support/oracle/plain_ledger')

# Several threads write to one meal at once, the way several phones do at
# dinner time, while another thread settles it. Each writer takes the meal
# row lock and re-checks the settlement under it, exactly as
# Api::V1::MealsController#with_meal_lock does, and retries a serialization
# failure the same way (RetryOnConflict). The settlement is the real one.
#
# Two phases. In the first the writers and the settler run together; the
# settler keeps trying until it wins. If the storm ends before it has won,
# the meal is given a bill and an eater and settled once more, so every run
# reaches the second phase: the same writers against the settled meal,
# where every write must be refused and nothing may change.
#
# What must hold at the end:
#   - every action ended in one of the outcomes the API knows how to
#     answer: written, refused by a rule, refused because settled, nothing
#     to do, or a conflict; never another exception, never a lock timeout;
#   - the storm finished (no deadlock);
#   - the rows are sound and the ledger over them agrees with the plain
#     ledger and sums to zero;
#   - the stored charges equal the ledger over the final rows, which is
#     only true if no write got through after the settlement;
#   - the rows after the second phase are the rows right after the
#     settlement;
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
  let(:noise) { Reconciliation::ZERO_SUM_EPSILON }

  # --- one write, the way the API does it -----------------------------------

  # Returns the outcome. The block gets the locked meal and returns true
  # (written), false (refused by a validation or a destroy guard) or nil
  # (nothing to do).
  def locked_write(meal_id)
    RetryOnConflict.call do
      Meal.transaction do
        meal = Meal.lock.find(meal_id)
        next :refused_settled if meal.reconciled?

        case yield(meal)
        when true then :ok
        when false then :refused
        else :noop
        end
      end
    end
  rescue ActiveRecord::TransactionRollbackError
    :conflict
  rescue ActiveRecord::LockWaitTimeout
    :lock_timeout
  rescue StandardError => e
    [:error, "#{e.class}: #{e.message}"]
  end

  # true when the row went, false when a guard refused, nil when there was none.
  def destroyed(row)
    return nil if row.nil?

    row.destroy != false
  end

  def write(meal_id, action, rng)
    case action
    when :set_bills then write_bills(meal_id, rng)
    when :close then locked_write(meal_id) { |meal| meal.update(closed: true) }
    when :reopen then locked_write(meal_id) { |meal| meal.update(closed: false) }
    else write_person(meal_id, action, residents.sample(random: rng), rng)
    end
  end

  def write_person(meal_id, action, resident, rng)
    case action
    when :signup
      locked_write(meal_id) do |meal|
        row = meal.meal_residents.find_or_initialize_by(resident_id: resident.id)
        row.late = rng.rand < 0.3
        row.save
      end
    when :leave
      locked_write(meal_id) { |meal| destroyed(meal.meal_residents.find_by(resident_id: resident.id)) }
    when :add_guest
      locked_write(meal_id) { |meal| Guest.new(meal_id: meal.id, resident_id: resident.id, vegetarian: false).save }
    when :remove_guest
      locked_write(meal_id) { |meal| destroyed(meal.guests.order(:id).first) }
    end
  end

  # The core of Api::V1::MealsController#update_bills: cooks left out go,
  # the rest are written.
  def write_bills(meal_id, rng)
    cooks = residents.sample(rng.rand(1..3), random: rng)
    amounts = cooks.to_h { |c| [c.id, BigDecimal(rng.rand(0..999_999)) / 100] }
    locked_write(meal_id) do |meal|
      meal.bills.where.not(resident_id: cooks.map(&:id)).find_each(&:destroy!)
      amounts.each do |id, amount|
        meal.bills.find_or_initialize_by(resident_id: id).update!(amount: amount, no_cost: false)
      end
      true
    end
  end

  def actions = %i[signup signup signup leave leave add_guest remove_guest set_bills set_bills close reopen]

  # --- the storm --------------------------------------------------------------

  def run_writers(meal_id, seed, rounds, log)
    Array.new(4) do |t|
      Thread.new do
        Thread.current.report_on_exception = false
        rng = Random.new((seed * 100) + t)
        ActiveRecord::Base.connection_pool.with_connection do
          rounds.times do |i|
            action = actions.sample(random: rng)
            outcome = write(meal_id, action, rng)
            log << [t, i, action, outcome]
            sleep(rng.rand * 0.002)
          end
        end
      end
    end
  end

  def run_settler(seed, log)
    Thread.new do
      Thread.current.report_on_exception = false
      rng = Random.new(seed)
      ActiveRecord::Base.connection_pool.with_connection do
        # Not before the writers have done a good part of their work, so
        # phase 1 always has writes on both sides of the settlement.
        sleep(0.005) until log.size >= 40 + rng.rand(20)
        # The real entry point, with its own patient retries. Giving up
        # (ActiveRecord::TransactionRollbackError) is not rescued: it would
        # be an :error outcome, and the storm asserts there are none. With
        # the request defaults it happened in two of five storms.
        40.times do
          reconciliation = SettleAndNotify.call(cutoff: Date.yesterday)
          log << [:settler, 0, :settle, [:settled, reconciliation.id]]
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

  def settle_for_sure(meal_id)
    return if Meal.find(meal_id).reconciled?

    write(meal_id, :set_bills, Random.new(1))
    locked_write(meal_id) { |m| m.update(closed: false) }
    locked_write(meal_id) { |m| m.meal_residents.find_or_initialize_by(resident_id: residents.first.id).save }
    SettleAndNotify.call(cutoff: Date.yesterday)
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
    fine = %i[ok refused refused_settled noop conflict]
    bad = log.reject do |_, _, _, outcome|
      fine.include?(outcome) || (outcome.is_a?(Array) && outcome.first == :settled)
    end
    expect(bad).to be_empty, "#{label}: unexpected outcomes #{bad.inspect}"
  end

  def expect_close(actual, expected, label)
    (actual.keys | expected.keys).each do |id|
      a = actual.fetch(id, BigDecimal('0'))
      e = expected.fetch(id, BigDecimal('0'))
      expect((a - e).abs).to be <= noise, "#{label} for resident #{id}: #{a.to_s('F')} vs #{e.to_s('F')}"
    end
  end

  def expect_ledger_sound(meal_id, label)
    rows = Meal.preload(:bills, :meal_residents, :guests).find(meal_id)
    lines = MealLedger.new([rows]).lines
    expect(lines.sum(BigDecimal('0'), &:amount).abs).to be <= noise, "#{label}: lines do not sum to zero"
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

      writers = run_writers(meal_id, seed, 25, log)
      settler = run_settler(seed, log)
      join_all(writers + [settler], "storm #{seed}, phase 1")
      first = Array.new(log.size) { log.pop }
      expect_outcomes_clean(first, "storm #{seed}, phase 1")
      expect_ledger_sound(meal_id, "storm #{seed}, phase 1")

      settle_for_sure(meal_id)
      expect(Meal.find(meal_id)).to be_reconciled
      settled_rows = snapshot(meal_id)

      writers = run_writers(meal_id, seed + 1000, 10, log)
      join_all(writers, "storm #{seed}, phase 2")
      second = Array.new(log.size) { log.pop }
      expect_outcomes_clean(second, "storm #{seed}, phase 2")
      expect(second.map(&:last).uniq).to eq([:refused_settled]),
                                         "storm #{seed}, phase 2: outcomes #{second.map(&:last).tally}"
      expect(snapshot(meal_id)).to eq(settled_rows), "storm #{seed}, phase 2: the settled rows changed"
      expect_ledger_sound(meal_id, "storm #{seed}, phase 2")
      tally = first.map(&:last).map { |o| o.is_a?(Array) ? o.first : o }.tally
      RSpec.configuration.reporter.message("storm #{seed}: #{tally}") if ENV['STORM_TALLY']
      expect(tally.fetch(:ok, 0)).to be >= 10, "storm #{seed}: only #{tally[:ok]} writes went through: #{tally}"
    end
  end
end
