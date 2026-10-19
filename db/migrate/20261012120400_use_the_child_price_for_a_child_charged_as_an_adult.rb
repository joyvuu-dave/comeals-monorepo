# frozen_string_literal: true

# Changes sign-ups of a child under 5 from the adult price to the child
# price, on meals before free meals for small children began, and works
# out again each settlement that holds them. One of the history fixes the
# owner decided on 2026-10-12, run during the deploy so no person has to do
# it by hand.
#
# A sign-up keeps the price it was saved with (meal_residents.multiplier:
# 2 adult, 1 child, 0 free; Multiplier). In the production copy of
# 2026-10-11, a young child was saved at the child price for many months,
# then at the adult price on a few meals, then at the free price once free
# meals for small children began. The first free sign-up of anyone is on
# 2018-05-03, so free meals for small children seem to have begun then.
# The adult ones sit between the other two and look like a mistake made
# while the price setting was being changed. The owner chose the child
# price, the price that child paid on every meal before (option A,
# 2026-10-12): applying the free price would use a rule from after those
# meals.
#
# The rule, which names no one: a sign-up at the adult price, for a
# resident with a birthday who was under 5 on the meal's date, on a meal
# before 2018-05-03. Checked under the locks before anything is written:
# each such sign-up is on a settled meal, and each child it names was at
# the child price on every meal before their first adult one. This moves
# money, so any other state stops the deploy and changes nothing: a person
# looks first. No sign-up matching (any database but production, or after
# this ran) is not an error.
#
# Each settlement is worked out again with Settlement#correct!, exactly as
# migration 20261010130000 does, for the reasons given there: the same
# settlement row, meals and cutoff, the settlement's own arithmetic, a
# refusal before any write if the settlement already disagrees with its
# rows, and a record of each balance before and after, which the query in
# docs/runbooks/settled-data-repair.md reads. A settlement made before
# line items existed gets them, written from the same ledger. The sign-ups
# change inside correct!, with the repair bypass on for that one UPDATE.
# Each gets the audit row a save would write ({"multiplier": [2, 1]}, so
# the meal history says "Adult to Child"), with no person and no username
# and this migration in the comment. updated_at moves on the sign-ups and
# their meals, so the calendar's cache version moves.
#
# Runs in its own transaction and tries again on a conflict, like
# 20261010130000. down puts the adult price back on exactly the sign-ups it
# changed, unless one changed since, and works each settlement out again
# with a correction of its own that says why.
class UseTheChildPriceForAChildChargedAsAnAdult < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  BY = 'Automatic fix (migration 20261012120400).'
  COMMENT = "#{BY} Changed this sign-up from the adult price to the child price. The child was under 5 on the " \
            "meal's date, before free meals for small children began on 2018-05-03, and paid the child price " \
            'on every meal before.'.freeze
  FREE_MEALS_BEGAN = Date.new(2018, 5, 3)
  UNDER = 5
  ADULT = 2
  CHILD = 1
  ATTEMPTS = 5

  Row = Struct.new(:id, :meal_id, :resident_id, :date, :reconciliation_id)
  Corrected = Struct.new(:reconciliation_id, :sign_ups, :changed)

  def up
    with_retry { connection.transaction { fix } }.each { |line| say line }
  end

  def down
    with_retry { connection.transaction { undo } }.each { |line| say line }
  end

  private

  # Returns the lines to print.
  def fix
    lock_meals("SELECT meal_residents.meal_id FROM meal_residents #{matching}")
    rows = connection.select_rows(<<~SQL.squish).map { |row| Row.new(*row) }
      SELECT meal_residents.id, meal_residents.meal_id, meal_residents.resident_id, meals.date, meals.reconciliation_id
      FROM meal_residents #{matching}
      ORDER BY meals.date, meal_residents.id
    SQL
    return ["No sign-up of a child under #{UNDER} is at the adult price before #{FREE_MEALS_BEGAN}."] if rows.empty?

    check(rows)
    now = Time.current.utc
    corrected = correct(rows, reason(rows)) { |own| set_price(own, CHILD, now) }
    write_rows(rows, now)
    touch_meals(rows, now)
    rows.map { |row| "#{row.date}  resident #{row.resident_id}  Adult to Child" } + report(corrected)
  end

  # The sign-ups the rule finds, joined to their meal and resident.
  def matching
    <<~SQL.squish
      JOIN meals ON meals.id = meal_residents.meal_id
      JOIN residents ON residents.id = meal_residents.resident_id
      WHERE meal_residents.multiplier = #{ADULT}
        AND residents.birthday IS NOT NULL
        AND meals.date < #{connection.quote(FREE_MEALS_BEGAN)}
        AND meals.date < (residents.birthday + INTERVAL '#{UNDER} years')::date
    SQL
  end

  # The meals' row locks, in id order, the order every meal write uses.
  def lock_meals(ids_sql)
    connection.execute("SELECT id FROM meals WHERE id IN (#{ids_sql}) ORDER BY id FOR UPDATE")
  end

  def check(rows)
    open = rows.select { |row| row.reconciliation_id.nil? }
    refuse("#{open.size} of them are on meals not settled: #{dates(open)}") unless open.empty?

    rows.group_by(&:resident_id).each do |resident_id, own|
      first = own.map(&:date).min
      other = connection.select_values(<<~SQL.squish).map(&:to_i).uniq
        SELECT meal_residents.multiplier FROM meal_residents JOIN meals ON meals.id = meal_residents.meal_id
        WHERE meal_residents.resident_id = #{Integer(resident_id)} AND meals.date < #{connection.quote(first)}
      SQL
      next if other == [CHILD]

      refuse("resident #{resident_id} was not at the child price on every meal before #{first} " \
             "(prices #{other.sort.inspect}), so the reason this migration gives would not be true")
    end
  end

  def reason(rows)
    "#{rows.size} sign-ups for a child under #{UNDER} were saved at the adult price. These numbers use the child " \
      'price, which the same child paid on every meal before.'
  end

  # Each settlement that holds one of the rows, oldest settlement id first,
  # worked out again with the block's change inside it. Returns what it did.
  def correct(rows, reason)
    reload_models
    rows.group_by(&:reconciliation_id).sort.map do |reconciliation_id, own|
      reconciliation = Reconciliation.find(reconciliation_id)
      correction = Settlement.new(reconciliation).correct!(reason: reason) { with_settled_writes { yield own } }
      Corrected.new(reconciliation_id, own.size, correction.lines.count)
    end
  end

  def set_price(rows, price, now)
    connection.execute(<<~SQL.squish)
      UPDATE meal_residents SET multiplier = #{Integer(price)}, updated_at = #{connection.quote(now)}
      WHERE id IN (#{ids(rows)})
    SQL
  end

  def write_rows(rows, now)
    connection.execute(<<~SQL.squish)
      INSERT INTO audits (auditable_type, auditable_id, associated_type, associated_id, action,
                          audited_changes, version, comment, username, request_uuid, created_at)
      SELECT 'MealResident', meal_residents.id, 'Meal', meal_residents.meal_id, 'update',
             '{"multiplier": [#{ADULT}, #{CHILD}]}'::jsonb,
             COALESCE((SELECT MAX(audits.version) FROM audits
                       WHERE audits.auditable_type = 'MealResident' AND audits.auditable_id = meal_residents.id),
                      0) + 1,
             #{connection.quote(COMMENT)}, NULL, #{connection.quote(SecureRandom.uuid)}, #{connection.quote(now)}
      FROM meal_residents WHERE meal_residents.id IN (#{ids(rows)})
      ORDER BY meal_residents.id
    SQL
  end

  def touch_meals(rows, now)
    meal_ids = rows.map { |row| Integer(row.meal_id) }.uniq.join(', ')
    connection.execute("UPDATE meals SET updated_at = #{connection.quote(now)} WHERE id IN (#{meal_ids})")
  end

  def report(corrected)
    corrected.map do |settlement|
      "Worked out settlement #{settlement.reconciliation_id} again for its #{settlement.sign_ups} sign-up(s): " \
        "#{settlement.changed} balance(s) changed. The query in docs/runbooks/settled-data-repair.md lists them."
    end
  end

  # Returns the lines to print.
  def undo
    audits = connection.select_rows(<<~SQL.squish)
      SELECT audits.id, audits.auditable_id, audits.created_at FROM audits
      WHERE audits.auditable_type = 'MealResident' AND audits.action = 'update'
        AND audits.comment = #{connection.quote(COMMENT)}
      ORDER BY audits.auditable_id
    SQL
    return ['This migration changed no sign-up: nothing to put back.'] if audits.empty?

    lock_meals("SELECT meal_id FROM meal_residents WHERE id IN (#{audits.map { |row| Integer(row[1]) }.join(', ')})")
    rows = unchanged(audits)
    now = Time.current.utc
    corrected = correct(rows, undo_reason(rows)) { |own| set_price(own, ADULT, now) }
    touch_meals(rows, now)
    connection.execute("DELETE FROM audits WHERE id IN (#{audits.map { |row| Integer(row[0]) }.join(', ')})")
    ["Put the adult price back on #{rows.size} sign-up(s)."] + report(corrected)
  end

  # The sign-ups this changed, if none changed since. Otherwise putting the
  # adult price back would undo that change.
  def unchanged(audits)
    rows = audits.map do |audit_id, sign_up_id, at|
      connection.select_rows(<<~SQL.squish).map { |row| Row.new(*row) }.first
        SELECT meal_residents.id, meal_residents.meal_id, meal_residents.resident_id, meals.date,
               meals.reconciliation_id
        FROM meal_residents JOIN meals ON meals.id = meal_residents.meal_id
        WHERE meal_residents.id = #{Integer(sign_up_id)} AND meal_residents.multiplier = #{CHILD}
          AND meal_residents.updated_at = #{connection.quote(at)}
          AND NOT EXISTS (SELECT 1 FROM audits later WHERE later.auditable_type = 'MealResident'
                          AND later.auditable_id = #{Integer(sign_up_id)} AND later.id > #{Integer(audit_id)})
      SQL
    end
    return rows unless rows.any?(&:nil?)

    raise "#{rows.count(&:nil?)} sign-up(s) this migration changed have changed since, so putting the adult " \
          'price back would undo that change. Nothing was changed.'
  end

  def undo_reason(rows)
    "Migration 20261012120400 was rolled back, so these #{rows.size} sign-ups are at the adult price again. " \
      'These numbers use the adult price again.'
  end

  # The repair bypass for exactly the statements in the block. If the block
  # raises, the transaction is rolled back, and that ends the setting too.
  def with_settled_writes
    connection.execute("SET LOCAL comeals.allow_settled_writes = 'on'")
    yield
    connection.execute("SET LOCAL comeals.allow_settled_writes = 'off'")
  end

  # The settlement code reads columns through these models. An earlier
  # migration in the same db:migrate run may have changed a table after a
  # model first read it.
  def reload_models
    [Reconciliation, ReconciliationBalance, MealCharge, Meal, Bill, MealResident, Guest, Resident,
     SettlementCorrection, SettlementCorrectionLine, SettlementCorrectionCharge].each(&:reset_column_information)
  end

  def refuse(why)
    raise "Migration 20261012120400 expected sign-ups of a child under #{UNDER} at the adult price, but #{why}. " \
          'Nothing was changed. Look at those sign-ups, then fix the data or this migration.'
  end

  def ids(rows)
    rows.map { |row| Integer(row.id) }.join(', ')
  end

  def dates(rows)
    rows.map(&:date).uniq.join(', ')
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
end
