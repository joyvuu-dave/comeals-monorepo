# frozen_string_literal: true

# Changes one cook's cost on the dinner of 2024-11-14 from $170.00 to the
# $17.00 the cook spent. One of the history fixes the owner decided on
# 2026-10-12, run during the deploy so no person has to do it by hand.
#
# A month after the dinner the cook cleared a box that held $1.00 and
# typed the cost. The history shows 1 saved, then 17 two seconds later,
# then 170 a quarter of a second after that: the last key added a zero. $170.00 makes the dinner
# $15.19 for each adult, the highest of any dinner. The owner asked the
# cook (2026-10-12): it was $17.00. The dinner is not settled, so this is
# an ordinary change of an open meal, not a correction.
#
# The row is found by what is true of it, and checked under the meal's
# row lock before anything is written: the dinner of 2024-11-14 is not
# settled and has exactly one cost of $170.00, not No cost. This moves
# money, so any other state stops the deploy and changes nothing: a
# person looks first. Two states are not errors. With no meal on
# 2024-11-14 (any database but production) there is nothing to change.
# With a cost of $17.00 there and none of $170.00, it was changed already,
# by this migration or by the cook.
#
# Plain SQL, like migration 20261012120000 and for the same reasons. The
# change gets the audit row a save would write ({"amount": ["170.0",
# "17.0"]}), with no person and no username and this migration in the
# comment, so the meal history says "Automatic fix". updated_at moves on
# the meal, so the calendar's cache version moves.
#
# Runs in its own transaction and tries again on a conflict, like
# 20261010130000. down puts $170.00 back, unless the cost changed since or
# the dinner was settled since.
class FixACostTypedWithAnExtraZero < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  BY = 'Automatic fix (migration 20261013120200).'
  COMMENT = "#{BY} Changed a cost typed as $170.00 to the $17.00 the cook spent. The last key added a " \
            'zero.'.freeze
  DINNER = Date.new(2024, 11, 14)
  TYPED = BigDecimal('170')
  SPENT = BigDecimal('17')
  ATTEMPTS = 5

  CostRow = Struct.new(:id, :amount, :no_cost)

  def up
    say(with_retry { connection.transaction { fix } })
  end

  def down
    say(with_retry { connection.transaction { put_back } })
  end

  private

  # Returns what to print.
  def fix
    meal = lock_meal
    return "No meal on #{DINNER}: nothing to change." if meal.nil?

    costs = costs_on(meal['id'])
    typed = costs.select { |cost| amount_is?(cost, TYPED) }
    return "The cost on #{DINNER} is #{money(SPENT)} already: nothing to change." if done?(costs, typed)

    refuse('the dinner is settled') unless meal['reconciliation_id'].nil?
    refuse("it has #{typed.size} cost(s) of #{money(TYPED)}, not 1") unless typed.size == 1
    now = Time.current.utc
    set_amount(typed.first.id, SPENT, now)
    write_audit(typed.first.id, meal['id'], [TYPED, SPENT], now)
    touch_meal(meal['id'], now)
    "Changed the #{money(TYPED)} cost on #{DINNER} to #{money(SPENT)}."
  end

  def lock_meal
    connection.select_one(<<~SQL.squish)
      SELECT id, reconciliation_id FROM meals WHERE date = #{connection.quote(DINNER)} FOR UPDATE
    SQL
  end

  def costs_on(meal_id)
    connection.select_rows(<<~SQL.squish).map { |row| CostRow.new(*row) }
      SELECT id, amount, no_cost FROM bills WHERE meal_id = #{Integer(meal_id)} ORDER BY id
    SQL
  end

  def done?(costs, typed)
    typed.empty? && costs.any? { |cost| amount_is?(cost, SPENT) }
  end

  def amount_is?(cost, amount)
    BigDecimal(cost.amount.to_s) == amount && !yes?(cost.no_cost)
  end

  def set_amount(bill_id, amount, now)
    connection.execute(<<~SQL.squish)
      UPDATE bills SET amount = #{connection.quote(amount)}, updated_at = #{connection.quote(now)}
      WHERE id = #{Integer(bill_id)}
    SQL
  end

  # The update row a save writes: the amount as text, as BigDecimal#as_json
  # gives it.
  def write_audit(bill_id, meal_id, change, now)
    changes = { 'amount' => change.map(&:to_s) }
    connection.execute(<<~SQL.squish)
      INSERT INTO audits (auditable_type, auditable_id, associated_type, associated_id, action,
                          audited_changes, version, comment, username, request_uuid, created_at)
      VALUES ('Bill', #{Integer(bill_id)}, 'Meal', #{Integer(meal_id)}, 'update',
              #{connection.quote(changes.to_json)}::jsonb,
              COALESCE((SELECT MAX(version) FROM audits
                        WHERE auditable_type = 'Bill' AND auditable_id = #{Integer(bill_id)}), 0) + 1,
              #{connection.quote(COMMENT)}, NULL, #{connection.quote(SecureRandom.uuid)}, #{connection.quote(now)})
    SQL
  end

  def touch_meal(meal_id, now)
    connection.execute("UPDATE meals SET updated_at = #{connection.quote(now)} WHERE id = #{Integer(meal_id)}")
  end

  # Returns what to print.
  def put_back
    audit = connection.select_one(<<~SQL.squish)
      SELECT id, auditable_id, created_at FROM audits
      WHERE auditable_type = 'Bill' AND comment = #{connection.quote(COMMENT)}
    SQL
    return 'This migration changed no cost: nothing to put back.' if audit.nil?

    meal = lock_meal
    gone_or_settled = meal.nil? || !meal['reconciliation_id'].nil?
    raise "The dinner of #{DINNER} is gone or settled, so the cost cannot go back." if gone_or_settled

    unchanged!(audit)
    set_amount(audit['auditable_id'], TYPED, Time.current.utc)
    connection.execute("DELETE FROM audits WHERE id = #{Integer(audit['id'])}")
    touch_meal(meal['id'], Time.current.utc)
    "Put the #{money(TYPED)} cost back on #{DINNER}."
  end

  # Putting $170.00 back over a later change would undo that change.
  def unchanged!(audit)
    same = connection.select_value(<<~SQL.squish).to_i.positive?
      SELECT COUNT(*) FROM bills
      WHERE id = #{Integer(audit['auditable_id'])} AND amount = #{connection.quote(SPENT)} AND NOT no_cost
        AND updated_at = #{connection.quote(audit['created_at'])}
        AND NOT EXISTS (SELECT 1 FROM audits later WHERE later.auditable_type = 'Bill'
                        AND later.auditable_id = #{Integer(audit['auditable_id'])} AND later.id > #{Integer(audit['id'])})
    SQL
    raise 'The cost changed after the fix, so putting $170.00 back would undo that change.' unless same
  end

  def refuse(why)
    raise "Migration 20261013120200 expected one #{money(TYPED)} cost on the dinner of #{DINNER}, but #{why}. " \
          'Nothing was changed. Look at the dinner, then fix the data or this migration.'
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
