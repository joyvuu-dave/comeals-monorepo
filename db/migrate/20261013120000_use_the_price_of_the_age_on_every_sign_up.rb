# frozen_string_literal: true

# Gives each sign-up the price of the resident's age on the meal's date,
# where the resident has a birthday and the saved price is a different
# one, and works out again each settlement that holds one. One of the
# history fixes the owner decided on 2026-10-12, run during the deploy so
# no person has to do it by hand.
#
# A sign-up keeps the price it was saved with (meal_residents.multiplier:
# 2 adult, 1 child, 0 free; Multiplier). Since #88 the app saves the price
# of the resident's age on the meal's date (Resident#multiplier_on). The
# release before saved the resident's price setting instead, and a person
# with no birthday on file kept the adult setting. On 2026-10-12 the owner
# gave the real birthdays of four children who had no birthday or a
# placeholder one, and they were entered in production by hand. With them
# in, the production copy of 2026-10-13 has 191 sign-ups whose price is
# not the price of the age: 26 in settlement 9 and 165 on meals not
# settled. The owner decided each one gets the price of the age: "All
# meals should be updated so this is fixed."
#
# The rule, which names no one: a sign-up on a meal from 2018-05-03 on,
# for a resident with a birthday, whose price is not the one the
# community's ages give for the age on the meal's date (free below
# free_below_age, child below full_price_age, adult from then on). The age
# is counted the way Resident#age_on and the adult_on scope count it.
# 2018-05-03 is the first free sign-up of anyone, so the rule of today was
# in use from then on; migration 20261012120400 decides the meals before
# it. A sign-up on a meal not settled is changed in place. A sign-up on a
# settled meal is changed inside Settlement#correct!, exactly as migration
# 20261012120400 does, for the reasons given there: the same settlement
# row, meals and cutoff, the settlement's own arithmetic, a refusal before
# any write if the settlement already disagrees with its rows, and a
# record of each balance before and after, which the query in
# docs/runbooks/settled-data-repair.md reads.
#
# This moves money, so it first checks, under the meals' row locks, the
# facts of the production copy of 2026-10-13: the sign-ups of 4 people
# change, and 26 of them are settled, all in one settlement. A birthday
# typed wrong before the deploy would change those facts, and would move
# old money if this went on. So any other state stops the deploy and
# changes nothing: a person looks first. So does a settlement that already
# disagrees with its rows (correct! refuses it). No sign-up matching (a
# database built from structure.sql, or after this ran) is not an error.
#
# Each sign-up gets the audit row a save would write ({"multiplier":
# [2, 0]}, so the meal history says "Adult to Child (free)"), with no
# person and no username and this migration in the comment. updated_at
# moves on the sign-ups and their meals, so the calendar's cache version
# moves. The balance cache for meals not settled is out of date until
# billing:recalculate runs next: bin/deploy runs it after a release, and
# otherwise the nightly job does.
#
# Runs in its own transaction and tries again on a conflict, like
# 20261010130000. down puts the old price back on exactly the sign-ups it
# changed, unless one changed since, and works each settlement out again
# with a correction of its own that says why.
class UseThePriceOfTheAgeOnEverySignUp < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  BY = 'Automatic fix (migration 20261013120000).'
  COMMENT = "#{BY} Changed this sign-up to the price of the person's age on the meal's date, from their " \
            'birthday.'.freeze
  RULE_BEGAN = Date.new(2018, 5, 3)
  # The facts of the production copy of 2026-10-13. See the header.
  PEOPLE = 4
  SETTLED_SIGN_UPS = 26
  # The words of Multiplier.label, written out so this migration does the
  # same on every database it ever runs on.
  NAMES = { 2 => 'Adult', 1 => 'Child', 0 => 'Child (free)' }.freeze
  ATTEMPTS = 5

  Row = Struct.new(:id, :meal_id, :resident_id, :date, :reconciliation_id, :saved, :price)
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
      SELECT meal_residents.id, meal_residents.meal_id, meal_residents.resident_id, meals.date,
             meals.reconciliation_id, meal_residents.multiplier, #{price}
      FROM meal_residents #{matching}
      ORDER BY meal_residents.resident_id, meals.date, meal_residents.id
    SQL
    return ['No sign-up of a person with a birthday is at a price other than the price of their age.'] if rows.empty?

    now = Time.current.utc
    settled, open = rows.partition(&:reconciliation_id)
    check(rows, settled)
    corrected = correct(settled, method(:reason)) { |own| set_prices(own, now, &:price) }
    set_prices(open, now, &:price)
    write_rows(rows, now)
    touch_meals(rows, now)
    summary(rows) + report(corrected)
  end

  # The sign-ups the rule finds, joined to their meal, resident and
  # community.
  def matching
    <<~SQL.squish
      JOIN meals ON meals.id = meal_residents.meal_id
      JOIN residents ON residents.id = meal_residents.resident_id
      JOIN communities ON communities.id = residents.community_id
      WHERE residents.birthday IS NOT NULL
        AND meals.date >= #{connection.quote(RULE_BEGAN)}
        AND meal_residents.multiplier <> #{price}
    SQL
  end

  # The price of the age on the meal's date, from the community's ages.
  def price
    <<~SQL.squish
      CASE WHEN #{age} < communities.free_below_age THEN 0
           WHEN #{age} < communities.full_price_age THEN 1
           ELSE 2 END
    SQL
  end

  # A year is added on the birthday itself, as in Resident.adult_on.
  def age
    <<~SQL.squish
      (EXTRACT(YEAR FROM meals.date) - EXTRACT(YEAR FROM residents.birthday)
       - CASE WHEN to_char(meals.date, 'MMDD') < to_char(residents.birthday, 'MMDD') THEN 1 ELSE 0 END)
    SQL
  end

  # The meals' row locks, in id order, the order every meal write uses.
  def lock_meals(ids_sql)
    connection.execute("SELECT id FROM meals WHERE id IN (#{ids_sql}) ORDER BY id FOR UPDATE")
  end

  def check(rows, settled)
    people = rows.map(&:resident_id).uniq.size
    refuse("they are the sign-ups of #{people} people, not #{PEOPLE}") unless people == PEOPLE
    settlements = settled.map(&:reconciliation_id).uniq.size
    return if settled.size == SETTLED_SIGN_UPS && settlements == 1

    refuse("#{settled.size} of them are settled, in #{settlements} settlement(s), not #{SETTLED_SIGN_UPS} in 1")
  end

  def reason(count)
    "Sign-ups saved at a price other than the price of the person's age on the meal's date: #{count}. " \
      'These numbers use the price of the age, from the birthday.'
  end

  # Each settlement that holds one of the rows, oldest settlement id first,
  # worked out again with the block's change inside it, under the reason
  # the method gives for its own count. Returns what it did.
  def correct(rows, reason)
    return [] if rows.empty?

    reload_models
    rows.group_by(&:reconciliation_id).sort.map do |reconciliation_id, own|
      reconciliation = Reconciliation.find(reconciliation_id)
      correction = Settlement.new(reconciliation)
                             .correct!(reason: reason.call(own.size)) { with_settled_writes { yield own } }
      Corrected.new(reconciliation_id, own.size, correction.lines.count)
    end
  end

  # One UPDATE for each price the block gives.
  def set_prices(rows, now)
    rows.group_by { |row| Integer(yield(row)) }.each do |price, own|
      connection.execute(<<~SQL.squish)
        UPDATE meal_residents SET multiplier = #{price}, updated_at = #{connection.quote(now)}
        WHERE id IN (#{ids(own)})
      SQL
    end
  end

  def write_rows(rows, now)
    request = SecureRandom.uuid
    values = rows.map do |row|
      changes = { 'multiplier' => [Integer(row.saved), Integer(row.price)] }.to_json
      "(#{Integer(row.id)}, #{Integer(row.meal_id)}, #{connection.quote(changes)}::jsonb)"
    end
    connection.execute(<<~SQL.squish)
      INSERT INTO audits (auditable_type, auditable_id, associated_type, associated_id, action,
                          audited_changes, version, comment, username, request_uuid, created_at)
      SELECT 'MealResident', changed.id, 'Meal', changed.meal_id, 'update', changed.changes,
             COALESCE((SELECT MAX(audits.version) FROM audits
                       WHERE audits.auditable_type = 'MealResident' AND audits.auditable_id = changed.id), 0) + 1,
             #{connection.quote(COMMENT)}, NULL, #{connection.quote(request)}, #{connection.quote(now)}
      FROM (VALUES #{values.join(', ')}) AS changed (id, meal_id, changes)
      ORDER BY changed.id
    SQL
  end

  def touch_meals(rows, now)
    meal_ids = rows.map { |row| Integer(row.meal_id) }.uniq.join(', ')
    connection.execute("UPDATE meals SET updated_at = #{connection.quote(now)} WHERE id IN (#{meal_ids})")
  end

  # One line for each person, price change and settlement, so the release
  # log can be checked against the rehearsal's list.
  def summary(rows)
    groups = rows.group_by { |row| [row.resident_id, row.saved, row.price, row.reconciliation_id] }
    groups.map do |(resident_id, saved, new_price, reconciliation_id), own|
      where = reconciliation_id ? "in settlement #{reconciliation_id}" : 'not settled'
      dates = own.map(&:date)
      "resident #{resident_id}  #{own.size} sign-up(s) #{where}, #{dates.min} to #{dates.max}  " \
        "#{NAMES.fetch(Integer(saved))} to #{NAMES.fetch(Integer(new_price))}"
    end
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
      SELECT audits.id, audits.auditable_id, audits.created_at, audits.audited_changes FROM audits
      WHERE audits.auditable_type = 'MealResident' AND audits.action = 'update'
        AND audits.comment = #{connection.quote(COMMENT)}
      ORDER BY audits.auditable_id
    SQL
    return ['This migration changed no sign-up: nothing to put back.'] if audits.empty?

    lock_meals("SELECT meal_id FROM meal_residents WHERE id IN (#{audits.map { |row| Integer(row[1]) }.join(', ')})")
    rows = unchanged(audits)
    now = Time.current.utc
    settled, open = rows.partition(&:reconciliation_id)
    corrected = correct(settled, method(:undo_reason)) { |own| set_prices(own, now, &:saved) }
    set_prices(open, now, &:saved)
    touch_meals(rows, now)
    connection.execute("DELETE FROM audits WHERE id IN (#{audits.map { |row| Integer(row[0]) }.join(', ')})")
    ["Put the old price back on #{rows.size} sign-up(s)."] + report(corrected)
  end

  # The sign-ups this changed, each with the price it had before, if none
  # changed since. Otherwise putting the old price back would undo that
  # change.
  def unchanged(audits)
    rows = audits.map do |audit_id, sign_up_id, at, changes|
      was, now = JSON.parse(changes).fetch('multiplier')
      connection.select_rows(<<~SQL.squish).map { |row| Row.new(*row) }.first
        SELECT meal_residents.id, meal_residents.meal_id, meal_residents.resident_id, meals.date,
               meals.reconciliation_id, #{Integer(was)}, meal_residents.multiplier
        FROM meal_residents JOIN meals ON meals.id = meal_residents.meal_id
        WHERE meal_residents.id = #{Integer(sign_up_id)} AND meal_residents.multiplier = #{Integer(now)}
          AND meal_residents.updated_at = #{connection.quote(at)}
          AND NOT EXISTS (SELECT 1 FROM audits later WHERE later.auditable_type = 'MealResident'
                          AND later.auditable_id = #{Integer(sign_up_id)} AND later.id > #{Integer(audit_id)})
      SQL
    end
    return rows unless rows.any?(&:nil?)

    raise "#{rows.count(&:nil?)} sign-up(s) this migration changed have changed since, so putting the old price " \
          'back would undo that change. Nothing was changed.'
  end

  def undo_reason(count)
    "Migration 20261013120000 was rolled back, so the sign-ups it changed (#{count}) are at their old price " \
      'again. These numbers use the old price again.'
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
    raise 'Migration 20261013120000 expected the sign-ups at a price other than the price of the age to be the ' \
          "ones of the production copy of 2026-10-13, but #{why}. Nothing was changed. Look at those sign-ups and " \
          'the birthdays behind them, then fix the data or this migration.'
  end

  def ids(rows)
    rows.map { |row| Integer(row.id) }.join(', ')
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
