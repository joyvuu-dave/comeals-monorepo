# frozen_string_literal: true

# Marks No cost on the two $1.00 cook costs of the dinner of 2024-11-24.
# One of the history fixes the owner decided on 2026-10-16, run during the
# deploy so no person has to do it by hand.
#
# The dinner was set up on 2024-06-10 for the community's Thanksgiving
# potluck. People signed up for it on paper in the common house, not in
# the app. Two cooks were added with a cost of $1.00 each, and nobody
# signed up in the app, and there are no guests. The $1.00 costs are not
# real money. With them, a settlement holds the dinner back forever: a
# receipt with money on it and nobody to charge (ADR 0011 rule 3). With
# No cost, it settles and no money moves.
#
# No cost needs amount 0 (the CHECK bills_no_cost_means_no_amount), so
# each cost changes from $1.00 to $0.00 and No cost. Nobody is charged for
# this dinner, so this moves no money. So a dinner that is not exactly as
# expected is skipped and printed, and the deploy goes on: a settled or
# cancelled dinner, a sign-up or a guest, a cook added or removed, or a
# cost that is not $1.00. With no meal on 2024-11-24 (any database but
# production) there is nothing to change, which is not an error. With
# this migration's audit rows there, it ran already, and it says so.
#
# The costs are found by the dinner and their amount, not by id. Plain
# SQL, like migration 20261012120000 and for the same reasons. Each change
# gets the audit row a save would write ({"amount": ["1.0", "0.0"],
# "no_cost": [false, true]}), with no person and no username and this
# migration in the comment, so the meal history says "Automatic fix".
# updated_at moves on the meal, so the calendar's cache version moves.
#
# Runs in its own transaction and tries again on a conflict, like
# 20261010130000. down puts the two $1.00 costs back, unless one changed
# since or the dinner was settled since.
class MarkThePotluckCostsNoCost < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  BY = 'Automatic fix (migration 20261016130000).'
  COMMENT = "#{BY} Marked this $1.00 cost No cost. The dinner was a potluck with a paper sign-up, and the " \
            'cost was not real money.'.freeze
  DINNER = Date.new(2024, 11, 24)
  PLACEHOLDER = BigDecimal('1')
  COOKS = 2
  ATTEMPTS = 5

  CostRow = Struct.new(:id, :amount, :no_cost)
  # One audit row this migration wrote, read back by down.
  Marked = Struct.new(:audit_id, :bill_id, :at)

  def up
    say(with_retry { connection.transaction { fix } })
  end

  def down
    say(with_retry { connection.transaction { put_back } })
  end

  private

  # Returns what to print.
  def fix
    return 'This migration marked the potluck costs already: nothing to mark.' if done?

    meal = lock_meal
    return "No meal on #{DINNER}: nothing to mark." if meal.nil?

    costs = costs_on(meal['id'])
    why = skip_reason(meal, costs)
    return "#{DINNER}  skipped: #{why}" unless why.nil?

    now = Time.current.utc
    ids = costs.map { |cost| Integer(cost.id) }
    write_audits(ids, now)
    set_costs(ids, amount: 0, no_cost: true, now: now)
    touch_meal(meal['id'], now)
    "#{DINNER}  marked the #{COOKS} #{money(PLACEHOLDER)} costs No cost"
  end

  def done?
    connection.select_value(<<~SQL.squish).to_i.positive?
      SELECT COUNT(*) FROM audits WHERE auditable_type = 'Bill' AND comment = #{connection.quote(COMMENT)}
    SQL
  end

  def lock_meal
    connection.select_one(<<~SQL.squish)
      SELECT id, reconciliation_id, cancelled_at FROM meals WHERE date = #{connection.quote(DINNER)} FOR UPDATE
    SQL
  end

  def costs_on(meal_id)
    connection.select_rows(<<~SQL.squish).map { |row| CostRow.new(*row) }
      SELECT id, amount, no_cost FROM bills WHERE meal_id = #{Integer(meal_id)} ORDER BY id
    SQL
  end

  # nil when the dinner is exactly as expected.
  def skip_reason(meal, costs)
    return 'the dinner is settled' unless meal['reconciliation_id'].nil?
    return 'the dinner is cancelled' unless meal['cancelled_at'].nil?
    return "it has #{costs.size} cooks, not #{COOKS}" unless costs.size == COOKS
    unless costs.all? { |cost| placeholder?(cost) }
      return "a cost is not #{money(PLACEHOLDER)} (one may have been changed since)"
    end

    signed_up = count_on('meal_residents', meal['id'])
    return "#{signed_up} sign-up(s) in the app" if signed_up.positive?

    guests = count_on('guests', meal['id'])
    "#{guests} guest(s)" if guests.positive?
  end

  def placeholder?(cost)
    BigDecimal(cost.amount.to_s) == PLACEHOLDER && !yes?(cost.no_cost)
  end

  def count_on(table, meal_id)
    connection.select_value("SELECT COUNT(*) FROM #{table} WHERE meal_id = #{Integer(meal_id)}").to_i
  end

  # The update row a save writes: the amount as text, as BigDecimal#as_json
  # gives it.
  def write_audits(ids, now)
    changes = { 'amount' => [PLACEHOLDER.to_s, BigDecimal('0').to_s], 'no_cost' => [false, true] }.to_json
    connection.execute(<<~SQL.squish)
      INSERT INTO audits (auditable_type, auditable_id, associated_type, associated_id, action,
                          audited_changes, version, comment, username, request_uuid, created_at)
      SELECT 'Bill', bills.id, 'Meal', bills.meal_id, 'update', #{connection.quote(changes)}::jsonb,
             COALESCE((SELECT MAX(audits.version) FROM audits
                       WHERE audits.auditable_type = 'Bill' AND audits.auditable_id = bills.id), 0) + 1,
             #{connection.quote(COMMENT)}, NULL, #{connection.quote(SecureRandom.uuid)}, #{connection.quote(now)}
      FROM bills WHERE bills.id IN (#{ids.join(', ')})
      ORDER BY bills.id
    SQL
  end

  def set_costs(ids, amount:, no_cost:, now:)
    connection.execute(<<~SQL.squish)
      UPDATE bills SET amount = #{connection.quote(BigDecimal(amount.to_s))}, no_cost = #{no_cost},
                       updated_at = #{connection.quote(now)}
      WHERE id IN (#{ids.join(', ')})
    SQL
  end

  def touch_meal(meal_id, now)
    connection.execute("UPDATE meals SET updated_at = #{connection.quote(now)} WHERE id = #{Integer(meal_id)}")
  end

  # Returns what to print.
  def put_back
    rows = connection.select_rows(<<~SQL.squish).map { |row| Marked.new(*row) }
      SELECT id, auditable_id, created_at FROM audits
      WHERE auditable_type = 'Bill' AND comment = #{connection.quote(COMMENT)}
      ORDER BY auditable_id
    SQL
    return 'This migration marked no cost: nothing to put back.' if rows.empty?

    meal = lock_meal
    gone_or_settled = meal.nil? || !meal['reconciliation_id'].nil?
    raise "The dinner of #{DINNER} is gone or settled, so the costs cannot go back." if gone_or_settled

    rows.each { |row| unchanged!(row) }
    now = Time.current.utc
    set_costs(rows.map { |row| Integer(row.bill_id) }, amount: PLACEHOLDER, no_cost: false, now: now)
    touch_meal(meal['id'], now)
    connection.execute("DELETE FROM audits WHERE id IN (#{rows.map { |row| Integer(row.audit_id) }.join(', ')})")
    "Put the #{rows.size} #{money(PLACEHOLDER)} cost(s) back on #{DINNER}."
  end

  # Putting $1.00 back over a later change would undo that change.
  def unchanged!(row)
    same = connection.select_value(<<~SQL.squish).to_i.positive?
      SELECT COUNT(*) FROM bills
      WHERE id = #{Integer(row.bill_id)} AND amount = 0 AND no_cost
        AND updated_at = #{connection.quote(row.at)}
        AND NOT EXISTS (SELECT 1 FROM audits later WHERE later.auditable_type = 'Bill'
                        AND later.auditable_id = #{Integer(row.bill_id)} AND later.id > #{Integer(row.audit_id)})
    SQL
    return if same

    raise "Cost #{row.bill_id} changed after migration 20261016130000, so putting $1.00 back would undo that. " \
          'Nothing was changed.'
  end

  def with_retry
    attempt = 0
    begin
      attempt += 1
      yield
    rescue ActiveRecord::TransactionRollbackError, ActiveRecord::LockWaitTimeout
      raise if attempt >= ATTEMPTS || connection.transaction_open?

      say "PostgreSQL refused this for a conflict with another write. Trying again (#{attempt + 1} of #{ATTEMPTS}).",
          true
      sleep(0.1 * (2**attempt))
      retry
    end
  end

  # PostgreSQL's true and false, as the connection hands them back.
  def yes?(value)
    ActiveModel::Type::Boolean.new.cast(value) == true
  end

  def money(amount)
    ActiveSupport::NumberHelper.number_to_currency(BigDecimal(amount.to_s))
  end
end
