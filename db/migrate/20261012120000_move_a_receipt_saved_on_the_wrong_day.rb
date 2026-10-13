# frozen_string_literal: true

# Moves one cook's receipt from the meal it was typed on to the dinner it
# was for. One of the history fixes the owner decided on 2026-10-12, run
# during the deploy so no person has to do it by hand.
#
# A cook made a dessert for the progressive dinner of 2025-12-07 and typed
# its $20.22 receipt on the meal of 2025-12-09, with the note "dessert for
# progressive dinner 12/7". The dinner already had three cooks, and the
# meal page shows three cook rows, so there was no row for a fourth.
# Nobody signed up for 2025-12-09, so the receipt could never be charged
# to anyone, and a settlement holds a meal like that back for good
# (Meal.settleable_by): the cook would never be paid back. On the dinner
# of 2025-12-07 the people who ate pay for it, the way they pay for the
# other three cooks' receipts. Neither meal is settled, so this is an
# ordinary change of two open meals, not a correction.
#
# A bill cannot change its meal (Bill::COOK_AND_MEAL_FIXED and the trigger
# bills_same_cook_and_meal), so the receipt is deleted from 2025-12-09 and
# made again on 2025-12-07, for the same cook (read from the bill, never
# named here) and the same amount.
#
# The rows are found by what is true of them, and every fact is checked
# under the meals' row locks before anything is written: the meal of
# 2025-12-09 has exactly one bill, of $20.22, not No cost, nobody signed
# up and no guest, and a note that names 12/7; the dinner of 2025-12-07 is
# not settled, someone ate at it, and the cook has no cost on it yet. This
# moves money, so any other state stops the deploy and changes nothing: a
# person looks first. Two states are not errors. With no meal on
# 2025-12-09 (any database but production) there is nothing to move. With
# the receipt already on 2025-12-07 and none left on 2025-12-09, the move
# was made already, by this migration or by hand.
#
# Plain SQL, like migration 20261010130000 and for the same reasons: a
# migration must do the same thing on every database it ever runs on, and
# a model changes over time. That also leaves out what a save through Bill
# would add and is not wanted from a release: its validations (the
# third-cook warning) and LiveUpdate's push. The meal history still shows
# the move, because this writes the audit rows a save would write: a
# delete row for the old bill and a create row for the new one, with no
# person and no username (the meal history of the release before this
# one answered 500 for a username with no person; see 20261010130000), and
# this migration in the comment, so the history says "Automatic fix".
# updated_at moves on both meals, so the calendar's cache version moves.
#
# Runs in its own transaction and tries again on a conflict, like
# 20261010130000. down puts the receipt back on 2025-12-09, with its old
# id, so its old audit rows name it again, unless the moved receipt
# changed since or the dinner was settled since.
class MoveAReceiptSavedOnTheWrongDay < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  BY = 'Automatic fix (migration 20261012120000).'
  COMMENT = "#{BY} Moved a receipt typed on the meal of 2025-12-09 to the dinner of 2025-12-07 it was " \
            'for. Nobody ate on 2025-12-09, so it could never be charged to anyone.'.freeze
  FROM = Date.new(2025, 12, 9)
  TO = Date.new(2025, 12, 7)
  AMOUNT = BigDecimal('20.22')
  NOTE = '12/7'
  ATTEMPTS = 5

  MealRow = Struct.new(:id, :date, :reconciliation_id, :description)
  ReceiptRow = Struct.new(:id, :resident_id, :amount, :no_cost, :community_id)
  # One audit row to write: which bill, on which meal, what happened.
  AuditRow = Struct.new(:bill_id, :meal_id, :action, :version, :changes)

  def up
    say(with_retry { connection.transaction { move } })
  end

  def down
    say(with_retry { connection.transaction { put_back } })
  end

  private

  # Returns what to print.
  def move
    from, to = lock_meals
    return "No meal on #{FROM}: nothing to move." if from.nil?

    receipts = receipts_on(from.id)
    return "The receipt is already on #{TO}, and none is left on #{FROM}: nothing to move." if moved?(receipts, to)

    receipt = expected_receipt(from, receipts)
    check_dinner(to, receipt)
    write_move(from, to, receipt)
    "Moved the #{money(receipt.amount)} receipt of resident #{receipt.resident_id} from #{FROM} to #{TO}."
  end

  # Both meals, locked in id order, the order every meal write uses.
  def lock_meals
    rows = connection.select_rows(<<~SQL.squish).map { |row| MealRow.new(*row) }
      SELECT id, date, reconciliation_id, description FROM meals
      WHERE date IN (#{connection.quote(FROM)}, #{connection.quote(TO)})
      ORDER BY id
      FOR UPDATE
    SQL
    [rows.find { |meal| meal.date.to_date == FROM }, rows.find { |meal| meal.date.to_date == TO }]
  end

  def receipts_on(meal_id)
    connection.select_rows(<<~SQL.squish).map { |row| ReceiptRow.new(*row) }
      SELECT id, resident_id, amount, no_cost, community_id FROM bills WHERE meal_id = #{Integer(meal_id)} ORDER BY id
    SQL
  end

  def moved?(receipts_on_from, to)
    receipts_on_from.empty? && !to.nil? &&
      connection.select_value(<<~SQL.squish).to_i.positive?
        SELECT COUNT(*) FROM bills
        WHERE meal_id = #{Integer(to.id)} AND amount = #{connection.quote(AMOUNT)} AND NOT no_cost
      SQL
  end

  def expected_receipt(from, receipts)
    refuse("the meal of #{FROM} is settled") unless from.reconciliation_id.nil?
    refuse("the meal of #{FROM} has #{receipts.size} cost(s), not 1") unless receipts.size == 1
    receipt = receipts.first
    unless BigDecimal(receipt.amount.to_s) == AMOUNT
      refuse("its cost is #{money(receipt.amount)}, not #{money(AMOUNT)}")
    end
    refuse('its cost is marked No cost') if yes?(receipt.no_cost)
    refuse("its note does not name #{NOTE}") unless from.description.to_s.include?(NOTE)
    refuse("someone signed up for #{FROM}, or brought a guest") if anyone_ate?(from.id)
    receipt
  end

  def check_dinner(to, receipt)
    refuse("there is no meal on #{TO}") if to.nil?
    refuse("the dinner of #{TO} is settled") unless to.reconciliation_id.nil?
    refuse("nobody ate at the dinner of #{TO}") unless anyone_ate?(to.id)
    taken = connection.select_value(<<~SQL.squish).to_i
      SELECT COUNT(*) FROM bills WHERE meal_id = #{Integer(to.id)} AND resident_id = #{Integer(receipt.resident_id)}
    SQL
    refuse("the cook already has a cost on the dinner of #{TO}") if taken.positive?
  end

  def anyone_ate?(meal_id)
    connection.select_value(<<~SQL.squish).to_i.positive?
      SELECT (SELECT COUNT(*) FROM meal_residents WHERE meal_id = #{Integer(meal_id)})
           + (SELECT COUNT(*) FROM guests WHERE meal_id = #{Integer(meal_id)})
    SQL
  end

  def write_move(from, to, receipt)
    now = Time.current.utc
    request = SecureRandom.uuid
    version = connection.select_value(<<~SQL.squish).to_i + 1
      SELECT COALESCE(MAX(version), 0) FROM audits WHERE auditable_type = 'Bill' AND auditable_id = #{Integer(receipt.id)}
    SQL
    write_audit(AuditRow.new(receipt.id, from.id, 'destroy', version, bill_changes(receipt, from.id)), now, request)
    connection.execute("DELETE FROM bills WHERE id = #{Integer(receipt.id)}")
    new_id = insert_bill(nil, to.id, receipt, now, now)
    write_audit(AuditRow.new(new_id, to.id, 'create', 1, bill_changes(receipt, to.id)), now, request)
    touch_meals([from.id, to.id], now)
  end

  # The bill's audited columns, the way audited writes them for a create
  # or a delete: the amount as text, as BigDecimal#as_json gives it.
  def bill_changes(receipt, meal_id)
    { 'amount' => BigDecimal(receipt.amount.to_s).to_s, 'meal_id' => Integer(meal_id),
      'no_cost' => yes?(receipt.no_cost), 'resident_id' => Integer(receipt.resident_id),
      'community_id' => Integer(receipt.community_id) }
  end

  # Returns the new bill's id. id: the id to give it, or nil for the next one.
  def insert_bill(id, meal_id, receipt, created_at, updated_at)
    columns = %w[meal_id resident_id amount no_cost community_id created_at updated_at]
    values = [Integer(meal_id), Integer(receipt.resident_id), BigDecimal(receipt.amount.to_s), yes?(receipt.no_cost),
              Integer(receipt.community_id), created_at, updated_at]
    unless id.nil?
      columns.unshift('id')
      values.unshift(Integer(id))
    end
    connection.select_value(<<~SQL.squish)
      INSERT INTO bills (#{columns.join(', ')}) VALUES (#{values.map { |value| connection.quote(value) }.join(', ')})
      RETURNING id
    SQL
  end

  def write_audit(row, now, request)
    connection.execute(<<~SQL.squish)
      INSERT INTO audits (auditable_type, auditable_id, associated_type, associated_id, action,
                          audited_changes, version, comment, username, request_uuid, created_at)
      VALUES ('Bill', #{Integer(row.bill_id)}, 'Meal', #{Integer(row.meal_id)}, #{connection.quote(row.action)},
              #{connection.quote(row.changes.to_json)}::jsonb, #{Integer(row.version)}, #{connection.quote(COMMENT)},
              NULL, #{connection.quote(request)}, #{connection.quote(now)})
    SQL
  end

  def touch_meals(meal_ids, now)
    ids = meal_ids.map { |id| Integer(id) }.join(', ')
    connection.execute("UPDATE meals SET updated_at = #{connection.quote(now)} WHERE id IN (#{ids})")
  end

  # Returns what to print.
  def put_back
    created = connection.select_one(<<~SQL.squish)
      SELECT id, auditable_id, associated_id, created_at FROM audits
      WHERE auditable_type = 'Bill' AND action = 'create' AND comment = #{connection.quote(COMMENT)}
    SQL
    return 'This migration moved no receipt: nothing to put back.' if created.nil?

    removed = connection.select_one(<<~SQL.squish)
      SELECT id, auditable_id, associated_id FROM audits
      WHERE auditable_type = 'Bill' AND action = 'destroy' AND comment = #{connection.quote(COMMENT)}
    SQL
    from, to = lock_meals
    receipt = unchanged_receipt(created, to)
    now = Time.current.utc
    connection.execute("DELETE FROM bills WHERE id = #{Integer(receipt.id)}")
    insert_bill(removed['auditable_id'], from.id, receipt, first_written(removed['auditable_id']) || now, now)
    connection.execute("DELETE FROM audits WHERE id IN (#{Integer(created['id'])}, #{Integer(removed['id'])})")
    touch_meals([from.id, to.id], now)
    "Put the #{money(receipt.amount)} receipt back on #{FROM}."
  end

  # The moved receipt, if nothing changed it since the move. Otherwise
  # putting it back would undo that change.
  def unchanged_receipt(created, to)
    raise 'The dinner of 2025-12-07 was settled since the move, so the receipt cannot go back.' unless
      to.reconciliation_id.nil?

    receipt = connection.select_rows(<<~SQL.squish).map { |row| ReceiptRow.new(*row) }.first
      SELECT id, resident_id, amount, no_cost, community_id FROM bills
      WHERE id = #{Integer(created['auditable_id'])} AND updated_at = #{connection.quote(created['created_at'])}
        AND NOT EXISTS (SELECT 1 FROM audits WHERE auditable_type = 'Bill'
                        AND auditable_id = #{Integer(created['auditable_id'])} AND id > #{Integer(created['id'])})
    SQL
    raise 'The moved receipt changed after the move, so putting it back would undo that change.' if receipt.nil?

    receipt
  end

  # When the old bill was first written, from its create row, so the bill
  # put back keeps that time.
  def first_written(bill_id)
    connection.select_value(<<~SQL.squish)
      SELECT MIN(created_at) FROM audits WHERE auditable_type = 'Bill' AND auditable_id = #{Integer(bill_id)}
    SQL
  end

  def refuse(why)
    raise "Migration 20261012120000 expected to move one $20.22 receipt from #{FROM} to #{TO}, but #{why}. " \
          'Nothing was changed. Look at both meals, then fix the data or this migration.'
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
