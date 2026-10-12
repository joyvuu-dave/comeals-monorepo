# frozen_string_literal: true

# Turns No cost off on every bill that has No cost and an amount, and
# keeps the amount, and works out again every settlement that left one
# of those amounts out. Step 2 of 3: step 1 (20261010125900) added the
# CHECK bills_no_cost_means_no_amount NOT VALID, and step 3
# (20261010130200) validates it.
#
# "No cost" means the cook spent nothing. MealLedger leaves a no-cost bill
# out of the meal's cost, so a cook whose bill had both was credited $0
# for what they spent. Before April 2026 the meal page let a cost be typed
# into a row marked No cost without turning No cost off. The audit trail
# of every such bill in the production copy of September 2026 shows the
# amount typed, or typed again, after No cost was on. That copy has 27
# such bills: 16 on 13 meals not settled yet ($676.30), and 11 on 9
# settled meals (2020 to 2024, $342.77, 9 cooks, in settlements 3, 7 and
# 9). The production copy of 2026-10-11 has the same 27. The owner
# decided on 2026-10-10 that No cost and an amount together never happen
# on purpose, that this migration fixes all of them during the deploy,
# with no person doing anything, and that every settled number must be
# right too: "What's important now is that the app is in a perfect
# state." Nobody recorded what was paid or collected for those
# settlements, so their balances are worked out again rather than kept.
#
# On a meal not settled yet, the amount then counts in the meal's cost,
# and the next settlement credits the cook. A settlement that already
# claimed one of these bills is worked out again from its meals' rows as
# they are after the fix (Settlement#correct!): the same settlement row,
# the same meals, new line items and balances, and a SettlementCorrection
# that keeps each changed balance before and after, every line item it
# replaced, and the reason. No admin page shows that record; the query
# in docs/runbooks/settled-data-repair.md reads it. ledger:verify then
# finds every settlement matching its rows, with no exception.
#
# What this does, in one transaction:
#
#   1. Takes the row lock of each meal that has such a bill (SELECT ...
#      FOR UPDATE, in id order, the order LocksItsMealFirst and the
#      settlement use). So a bills save or a settlement running at the
#      same time waits for this, or this waits for it, and a meal not
#      settled yet stays that way until this commits.
#   2. Reads the bills again under those locks, and turns No cost off:
#      settlement by settlement on the settled meals, inside
#      Settlement#correct! (step 5), so a refusal there comes before any
#      write, then on the meals not settled yet. The
#      bills_reject_settled_write trigger refuses that on a settled meal,
#      so the repair bypass (comeals.allow_settled_writes,
#      docs/runbooks/settled-data-repair.md) is on for each UPDATE of
#      settled bills, and off again right after. Every row this writes
#      follows the CHECK of step 1.
#   3. Sets updated_at on each fixed bill and its meal, the way a save
#      through the model would (Bill touches its meal). The calendar's
#      cache version reads the newest updated_at
#      (Community#calendar_cache_version), so the next calendar read
#      builds the month again.
#   4. Writes one audits row for each bill, like the row audited writes
#      for a save: the next version of that bill, linked to its meal,
#      changes {"no_cost": [true, false]}. No person, and no username: a
#      row with a username and no person makes the meal history of the
#      release before this one (v613) answer 500, because it asks
#      audited's `user` for a name and gets the username, a String. That
#      release runs on this database if the deploy is rolled back
#      (#133). The comment says who and why, starting with BY, and the
#      meal history shows "Automatic fix" as who made the change
#      (AuditSerializer). The comment also says whether the meal was
#      already settled; down reads it. The meal history then says "Bill
#      for Jane no longer marked as no cost, so the $86.00 now counts in
#      the meal's cost" (AuditDescription), on a settled meal too, since
#      step 5 counts it.
#   5. Works out again each settlement that claimed one of the fixed
#      bills, found from the bills, not by id (Settlement#correct!), with
#      that settlement's bill fix of step 2 inside it. It runs before the
#      commit, so no reader ever sees a fixed bill next to the old
#      numbers. Before it changes anything, correct! asks the nightly
#      check about the settlement, and refuses if it already disagrees
#      with its rows: the correction would fold that earlier difference
#      in under this migration's reason. The whole migration then fails
#      and changes nothing, and the release fails. It uses the app's
#      settlement code, not a copy of the arithmetic in SQL: the new
#      numbers must be exactly the ones ledger:verify works out from the
#      same rows, and a second copy of the arithmetic could differ from
#      the first by a cent. The model classes read their columns again
#      first, in case an earlier migration of the same run changed them.
#   6. Prints each fixed bill (meal date, cook, amount), the totals, and
#      how many balances each settlement changed, so the release log
#      keeps a record.
#
# Rows are found by the condition, when this runs, not by a list of ids:
# production may have more or fewer than the September copy. Step 1's
# CHECK is already committed, so no new bill with both can be written
# after this has looked.
#
# Plain SQL for the bills, no model classes. A model changes over time
# (new validations, new callbacks, renamed columns), and a migration has
# to do the same thing on every database it ever runs on. This also skips
# what a save through Bill would do and is not wanted here: Bill's
# validations and LiveUpdate. Step 5 is the one exception, for the reason
# given there. It runs only when a fixed bill is on a settled meal, which
# is production and no other database, so a later change to the models
# cannot break a fresh db:migrate. No live push is sent; no screen shows
# a settlement's balances or line items outside admin. An open meal page finds the new
# release within five minutes (VersionBanner) and loads it when someone
# taps Refresh or nobody has used the screen for five minutes. Until then
# it may still show one of these bills as No cost with its amount. A save
# built on that view is refused, so nothing wrong is written: as stale
# (409), or, when the person picked another cook in that row, with
# Bill::NO_COST_MEANS_NO_AMOUNT (400). Either way the page reads the meal
# again.
#
# strong_migrations checks the schema changes a migration makes through
# its own methods. up changes rows through the connection, so there is
# nothing for it to check. The locks it takes, while the transaction
# runs: the rows of the meals that have such a bill and of the bills it
# changes; for each settlement it works out again, that settlement's row
# (FOR UPDATE, from correct!); and, through the foreign keys of the rows
# correct! writes, share locks (FOR KEY SHARE) on that settlement's meals
# and on the residents named. A share lock blocks only a delete of the
# row or a change of its id. The lock_timeout strong_migrations sets for
# every migration (10 seconds) still applies.
#
# The whole app runs at SERIALIZABLE (config/database.yml), so a bills
# save or a settlement that commits while this runs can make PostgreSQL
# refuse it for a conflict. That is why this runs its own transaction
# (disable_ddl_transaction!) and runs it again, like RetryOnConflict does
# for the API. If it still fails, nothing was written, the release fails,
# and the old release keeps serving.
#
# The running balances (resident_balances) are a cache that
# billing:recalculate rebuilds each night, so they show the fix the next
# morning, as they would after any bills save. They add up only meals not
# settled yet, so the settlements worked out again do not change them.
#
# down puts No cost back on exactly the bills this changed, found by its
# audit rows, and deletes those rows. It leaves a bill that changed after
# the fix. It refuses (changing nothing) when a bill it fixed on a meal
# not settled yet is now on a settled meal, because that settlement
# counted the amount. A bill of a meal that was already settled goes back
# with the bypass on: its settlement read it as No cost. Step 1's CHECK
# refuses what down puts back, so down drops the CHECK and adds it back
# NOT VALID in the same transaction. Step 3's down runs first and makes
# the CHECK NOT VALID; down refuses while it is still validated. down
# sets updated_at on the bills and meals to the time of the down, not back
# to what it was before the fix, because the calendar's cache version
# must change again. Each settlement up worked out again is worked out
# again once more, with its bills put back inside correct!, and with a
# correction of its own that says why: a correction is a record of what
# happened, so down adds one rather than deleting up's. Its balances are
# then the ones it had before up. Its line items are not: a settlement
# that had none before up (settlements 3, 7 and 9 in production) keeps
# line items from then on, written from the bills put back, so they add
# up to those balances. Up's correction keeps the line items it replaced.
class TurnOffNoCostOnBillsWithAnAmount < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  # Who made the change, at the start of each audit row's comment (see 4.
  # above). AuditSerializer::AUTOMATIC_FIX is the start of it.
  BY = 'Automatic fix (migration 20261010130000).'
  COMMENT = "#{BY} Turned No cost off and kept the amount. This bill was marked No cost and also had a cost " \
            'typed in, which the meal page allowed before April 2026. A bill marked No cost is left out ' \
            "of the meal's cost, so the cook would have been credited $0 for what they spent.".freeze
  SETTLED_COMMENT = "#{BY} Turned No cost off and kept the amount, on a meal that was already settled. This " \
                    'bill was marked No cost and also had a cost typed in, which the meal page allowed before ' \
                    "April 2026. The settlement had left the amount out of the meal's cost, so it was " \
                    'worked out again with the amount counted (Settlement#correct!).'.freeze
  CHECK_NAME = 'bills_no_cost_means_no_amount'
  CHECK_EXPRESSION = 'NOT no_cost OR amount = 0'
  ATTEMPTS = 5

  # A bill this fixes, as the release log names it. reconciliation_id: the
  # settlement that claimed its meal, or nil. settled: there is one.
  Fixed = Struct.new(:bill_id, :meal_id, :date, :cook, :amount, :reconciliation_id, :settled)
  # What step 5 did to one settlement, for the release log.
  Corrected = Struct.new(:reconciliation_id, :bills, :changed)
  # One of this migration's audit rows, and what down finds for it.
  # settled: the meal is settled now. settled_when_fixed: it was already
  # settled when the fix ran (the row has SETTLED_COMMENT), and
  # reconciliation_id is that settlement. as_fixed: the
  # bill is still there, No cost is still off, its updated_at is still
  # the fix's, and its history has no later row. If not, a person or the
  # app changed it since, and putting No cost back would undo that change.
  FixRow = Struct.new(:audit_id, :bill_id, :meal_id, :date, :settled, :as_fixed, :settled_when_fixed,
                      :reconciliation_id)

  def up
    fixed, corrected = with_retry { connection.transaction { fix } }
    report_fixed(fixed)
    report_corrected(corrected)
  end

  def down
    if yes?(check_validated)
      raise 'Roll back migration 20261010130200 first. It makes the CHECK ' \
            "#{CHECK_NAME} NOT VALID again, the state this migration ran in."
    end

    put_back, left, corrected = with_retry { connection.transaction { undo } }
    say "Put No cost back on #{put_back.size} bill(s)."
    report_corrected(corrected)
    return if left.empty?

    say "Left as it is, because it changed after the fix: #{bill_list(left)}. " \
        'Its row in the meal history stays.'
  end

  private

  # Returns [bills fixed, settlements worked out again].
  def fix
    meal_ids = connection.select_values(<<~SQL.squish)
      SELECT meals.id FROM meals
      WHERE EXISTS (SELECT 1 FROM bills WHERE bills.meal_id = meals.id AND bills.no_cost AND bills.amount > 0)
      ORDER BY meals.id
      FOR UPDATE
    SQL
    return [[], []] if meal_ids.empty?

    fixed = connection.select_rows(<<~SQL.squish).map { |row| fixed_bill(row) }
      SELECT bills.id, meals.id, meals.date, residents.name, bills.amount, meals.reconciliation_id
      FROM bills
      JOIN meals ON meals.id = bills.meal_id
      JOIN residents ON residents.id = bills.resident_id
      WHERE meals.id IN (#{id_list(meal_ids)}) AND bills.no_cost AND bills.amount > 0
      ORDER BY meals.date, residents.name, bills.id
    SQL
    return [[], []] if fixed.empty?

    [fixed, write_fix(fixed)]
  end

  def fixed_bill(row)
    bill = Fixed.new(*row)
    bill.settled = !bill.reconciliation_id.nil?
    bill
  end

  # Step 5: each settlement that claimed one of these bills, oldest
  # settlement id first. The block changes that settlement's own bills
  # (fixed, or from down, put back), and correct! then works it out again
  # from its rows as they are. correct! refuses a settlement that already
  # disagreed with its rows before the block (see 5. above). Returns what
  # it did, for the release log.
  def correct_settlements(bills, direction)
    return [] if bills.empty?

    reload_models
    bills.group_by(&:reconciliation_id).sort.map do |reconciliation_id, own|
      reconciliation = Reconciliation.find(reconciliation_id)
      reason = correction_reason(own.size, direction)
      correction = Settlement.new(reconciliation).correct!(reason: reason) { yield own }
      Corrected.new(reconciliation_id, own.size, correction.lines.count)
    end
  end

  # The reason each correction saves (settlement_corrections.reason).
  def correction_reason(count, direction)
    if direction == :undone
      return "Migration 20261010130000 was rolled back, so #{count} #{count == 1 ? 'cost' : 'costs'} on these " \
             "meals #{count == 1 ? 'is' : 'are'} marked No cost again. These numbers leave " \
             "#{count == 1 ? 'it' : 'them'} out again."
    end
    if count == 1
      return '1 cost on these meals was marked No cost by mistake, so its cook was credited $0 for it. ' \
             'These numbers now count that cost.'
    end

    "#{count} costs on these meals were marked No cost by mistake, so their cooks were credited $0 for them. " \
      'These numbers now count those costs.'
  end

  # The settlement code reads columns through these models. An earlier
  # migration in the same db:migrate run may have changed a table after a
  # model first read it.
  def reload_models
    [Reconciliation, ReconciliationBalance, MealCharge, Meal, Bill, MealResident, Guest, Resident,
     SettlementCorrection, SettlementCorrectionLine, SettlementCorrectionCharge].each(&:reset_column_information)
  end

  # Steps 2 to 5. Returns the settlements worked out again.
  def write_fix(fixed)
    now = connection.quote(Time.current.utc)
    request = connection.quote(SecureRandom.uuid)
    settled, open = fixed.partition(&:settled)
    corrected = correct_settlements(settled, :fixed) { |own| with_settled_writes { turn_no_cost_off(own, now) } }
    turn_no_cost_off(open, now)
    connection.execute("UPDATE meals SET updated_at = #{now} WHERE id IN (#{id_list(fixed.map(&:meal_id).uniq)})")
    write_rows(open, COMMENT, now, request)
    write_rows(settled, SETTLED_COMMENT, now, request)
    corrected
  end

  def turn_no_cost_off(bills, now)
    return if bills.empty?

    connection.execute(<<~SQL.squish)
      UPDATE bills SET no_cost = false, updated_at = #{now}
      WHERE id IN (#{id_list(bills.map(&:bill_id))}) AND no_cost AND amount > 0
    SQL
  end

  # The repair bypass for exactly the statements in the block. SET LOCAL
  # would keep it on until the transaction ends, so it is turned off
  # again. If the block raises, the transaction is rolled back, and that
  # ends the setting too.
  def with_settled_writes
    connection.execute("SET LOCAL comeals.allow_settled_writes = 'on'")
    yield
    connection.execute("SET LOCAL comeals.allow_settled_writes = 'off'")
  end

  def write_rows(bills, comment, now, request)
    return if bills.empty?

    connection.execute(<<~SQL.squish)
      INSERT INTO audits (auditable_type, auditable_id, associated_type, associated_id, action,
                          audited_changes, version, comment, username, request_uuid, created_at)
      SELECT 'Bill', bills.id, 'Meal', bills.meal_id, 'update', '{"no_cost": [true, false]}'::jsonb,
             COALESCE((SELECT MAX(audits.version) FROM audits
                       WHERE audits.auditable_type = 'Bill' AND audits.auditable_id = bills.id), 0) + 1,
             #{connection.quote(comment)}, NULL, #{request}, #{now}
      FROM bills WHERE bills.id IN (#{id_list(bills.map(&:bill_id))})
      ORDER BY bills.id
    SQL
  end

  def report_fixed(fixed)
    if fixed.empty?
      say 'No bill has both No cost and an amount.'
      return
    end

    fixed.each do |bill|
      say("#{bill.date}  #{bill.cook}  #{money(bill.amount)}#{'  (settled)' if bill.settled}", true)
    end
    settled, open = fixed.partition(&:settled)
    report_total(open, 'meal(s) not settled yet')
    report_total(settled, 'settled meal(s)')
  end

  def report_corrected(corrected)
    corrected.each do |settlement|
      say "Worked out settlement #{settlement.reconciliation_id} again for its #{settlement.bills} bill(s): " \
          "#{settlement.changed} balance(s) changed. " \
          'The query in docs/runbooks/settled-data-repair.md lists them.'
    end
  end

  def report_total(bills, meals)
    return if bills.empty?

    total = bills.sum(BigDecimal('0')) { |bill| BigDecimal(bill.amount.to_s) }
    say "Turned No cost off on #{bills.size} bill(s) on #{bills.map(&:meal_id).uniq.size} #{meals}, " \
        "#{money(total)} in all."
  end

  # Returns [rows put back, rows left, settlements worked out again].
  def undo
    connection.select_values(<<~SQL.squish)
      SELECT meals.id FROM meals
      WHERE meals.id IN (SELECT associated_id FROM audits WHERE #{fix_rows})
      ORDER BY meals.id
      FOR UPDATE
    SQL
    rows = connection.select_rows(<<~SQL.squish).map { |row| fix_row(row) }
      SELECT audits.id, audits.auditable_id, meals.id, meals.date, meals.reconciliation_id IS NOT NULL,
             bills.id IS NOT NULL AND NOT bills.no_cost AND bills.updated_at = audits.created_at
               AND NOT EXISTS (SELECT 1 FROM audits later
                               WHERE later.auditable_type = 'Bill' AND later.auditable_id = audits.auditable_id
                                 AND later.id > audits.id),
             audits.comment = #{connection.quote(SETTLED_COMMENT)}, meals.reconciliation_id
      FROM audits
      LEFT JOIN bills ON bills.id = audits.auditable_id
      LEFT JOIN meals ON meals.id = audits.associated_id
      WHERE #{fix_rows}
      ORDER BY meals.date, audits.auditable_id
    SQL
    as_fixed, left = rows.partition(&:as_fixed)
    refuse_settled(as_fixed.select { |row| row.settled && !row.settled_when_fixed })
    return [as_fixed, left, []] if as_fixed.empty?

    [as_fixed, left, write_undo(as_fixed)]
  end

  def fix_row(row)
    fix_row = FixRow.new(*row)
    fix_row.settled = yes?(fix_row.settled)
    fix_row.as_fixed = yes?(fix_row.as_fixed)
    fix_row.settled_when_fixed = yes?(fix_row.settled_when_fixed)
    fix_row
  end

  # Step 1's CHECK refuses a bill with both, so it is dropped while the
  # bills go back, and added back NOT VALID, as step 1 left it. All in
  # this transaction: no other write sees the table without it. Returns
  # the settlements worked out again.
  def write_undo(rows)
    now = connection.quote(Time.current.utc)
    check = connection.check_constraint_exists?(:bills, name: CHECK_NAME)
    connection.remove_check_constraint(:bills, name: CHECK_NAME) if check
    settled, open = rows.partition(&:settled_when_fixed)
    put_no_cost_back(open, now)
    corrected = correct_settlements(settled, :undone) { |own| with_settled_writes { put_no_cost_back(own, now) } }
    connection.add_check_constraint(:bills, CHECK_EXPRESSION, name: CHECK_NAME, validate: false) if check
    connection.execute("UPDATE meals SET updated_at = #{now} WHERE id IN (#{id_list(rows.map(&:meal_id).uniq)})")
    connection.execute("DELETE FROM audits WHERE id IN (#{id_list(rows.map(&:audit_id))})")
    corrected
  end

  def put_no_cost_back(rows, now)
    return if rows.empty?

    connection.execute(<<~SQL.squish)
      UPDATE bills SET no_cost = true, updated_at = #{now}
      WHERE id IN (#{id_list(rows.map(&:bill_id))}) AND NOT no_cost
    SQL
  end

  def refuse_settled(rows)
    return if rows.empty?

    raise "#{rows.size} bill(s) this migration fixed are on a meal settled since: #{bill_list(rows)}. " \
          'A settled meal cannot change, so this migration cannot be undone.'
  end

  # nil when the CHECK is not there.
  def check_validated
    connection.select_value(<<~SQL.squish)
      SELECT convalidated FROM pg_constraint
      WHERE conname = #{connection.quote(CHECK_NAME)} AND conrelid = 'bills'::regclass
    SQL
  end

  # This migration's audit rows: no person, no username, and one of its
  # two comments.
  def fix_rows
    "audits.auditable_type = 'Bill' AND audits.action = 'update' AND audits.user_id IS NULL " \
      "AND audits.username IS NULL AND audits.comment IN (#{connection.quote(COMMENT)}, " \
      "#{connection.quote(SETTLED_COMMENT)})"
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

  def bill_list(rows)
    rows.map { |row| "bill #{row.bill_id} (#{row.date || 'meal deleted'})" }.join(', ')
  end

  # PostgreSQL's true and false, as the connection hands them back.
  def yes?(value)
    ActiveModel::Type::Boolean.new.cast(value) == true
  end

  def id_list(ids)
    ids.map { |id| Integer(id) }.join(', ')
  end

  def money(amount)
    ActiveSupport::NumberHelper.number_to_currency(BigDecimal(amount.to_s))
  end
end
