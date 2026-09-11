# frozen_string_literal: true

require Rails.root.join('spec/support/oracle/plain_ledger')

module Storm
  # What must be true of the database after a storm, whatever happened
  # during it. Returns a list of problems, empty when all is well.
  #
  #   - every meal's rows are sound, and the ledger over them agrees with
  #     the plain ledger (the oracle) and sums to zero;
  #   - a settled meal's stored charges equal the ledger over its final
  #     rows, which is only true if no write got through after the
  #     settlement; its stored balances sum to zero;
  #   - ledger:verify passes;
  #   - a capped meal holds no more than its cap, and an open meal has no
  #     cap (the meal lock is what makes the cap hold under load);
  #   - the balance refresh is a pure function of the rows: running it
  #     twice gives the same table;
  #   - the calendar as cached is the calendar as built: every month the
  #     storm touched reads the same with the cache and without it. A
  #     stale entry that outlived the writes would show here.
  class Checks
    NOISE = Reconciliation::ZERO_SUM_EPSILON

    def self.call(plan:, transport:)
      new(plan, transport).call
    end

    def initialize(plan, transport)
      @plan = plan
      @transport = transport
      @problems = []
    end

    def call
      Meal.where(id: @plan.meal_ids).find_each { |meal| check_meal(meal) }
      @problems << 'ledger:verify fails' unless LedgerVerification.call.passed?
      check_balance_refresh
      check_calendar
      @problems
    end

    private

    def check_meal(meal)
      rows = Meal.preload(:bills, :meal_residents, :guests).find(meal.id)
      net = check_ledger(rows)
      check_cap(rows)
      check_settled(rows, net) if rows.reconciled?
    end

    # The net amount per resident, checked against the oracle.
    def check_ledger(rows)
      label = "meal #{rows.id}"
      lines = MealLedger.new([rows]).lines
      problem(label, 'lines do not sum to zero') if lines.sum(BigDecimal('0'), &:amount).abs > NOISE
      net = lines.group_by(&:resident_id).transform_values { |l| l.sum(BigDecimal('0'), &:amount) }
      expect_close(net, PlainLedger.net_by_meal([RandomLedger.plain(rows)]).transform_keys(&:last),
                   "#{label}: ledger and oracle differ")
      net
    end

    def check_cap(rows)
      label = "meal #{rows.id}"
      over = rows.max && rows.attendees_count > rows.max
      problem(label, "holds #{rows.attendees_count} with a cap of #{rows.max}") if over
      problem(label, "is open with a cap of #{rows.max}") if !rows.closed? && rows.max
    end

    def check_settled(rows, net)
      label = "meal #{rows.id}"
      expect_close(MealCharge.where(meal_id: rows.id).group(:resident_id).sum(:amount), net,
                   "#{label}: stored charges differ from the final rows")
      balances = ReconciliationBalance.where(reconciliation_id: rows.reconciliation_id).sum(:amount)
      problem(label, "settled balances sum to #{balances}") unless balances.zero?
    end

    def expect_close(actual, expected, label)
      (actual.keys | expected.keys).each do |id|
        a = actual.fetch(id, BigDecimal('0'))
        e = expected.fetch(id, BigDecimal('0'))
        @problems << "#{label} for resident #{id}: #{a.to_s('F')} vs #{e.to_s('F')}" if (a - e).abs > NOISE
      end
    end

    def problem(label, text)
      @problems << "#{label}: #{text}"
    end

    def check_balance_refresh
      first = balances_after_refresh
      second = balances_after_refresh
      @problems << "balance refresh is not stable: #{first.inspect} then #{second.inspect}" unless first == second
    end

    def balances_after_refresh
      BalanceRecalculation.call(community: @plan.community)
      ResidentBalance.order(:resident_id).pluck(:resident_id, :amount)
    end

    def check_calendar
      months = @plan.meals.map { |meal| meal.date.beginning_of_month }.uniq
      months.each do |month|
        cached = calendar(month)
        Rails.cache.clear
        fresh = calendar(month)
        next if cached == fresh

        @problems << "calendar #{month.strftime('%Y-%m')} as cached differs from the calendar as built:\n  " \
                     "cached: #{cached[0, 300]}\n  fresh:  #{fresh[0, 300]}"
      end
    end

    def calendar(month)
      resident = @plan.residents.first
      headers = { 'Authorization' => "Bearer #{@plan.tokens.fetch(resident.id)}" }
      status, body = @transport.call(:get, "/api/v1/communities/#{@plan.community.id}/calendar/#{month.iso8601}",
                                     headers, nil, '10.9.250.1')
      @problems << "calendar #{month} answered #{status}" unless status == 200
      body
    end
  end
end
