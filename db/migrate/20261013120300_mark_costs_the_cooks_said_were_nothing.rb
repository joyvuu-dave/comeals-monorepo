# frozen_string_literal: true

# Marks No cost on nine blank cook costs whose cooks spent nothing. One
# of the history fixes the owner decided on 2026-10-12 and 2026-10-13, run
# during the deploy so no person has to do it by hand.
#
# A blank cost (amount 0, not No cost) means the cook has not said what
# they spent, and under ADR 0011 rule 3 a dinner waits until every cook
# has. The audit of 2026-10-11 found 17 dinners with a blank cost, and the
# owner asked the cooks. On these nine the cooks said they spent nothing:
#
# - On eight dinners another cook of the same household entered the
#   receipt for both, and the blank cost is the other's. These are two
#   households. In each, the two often cook together, and usually one
#   enters the receipt and the other marks No cost.
# - On the dinner of 2024-11-03 the blank cost belongs to a cook who
#   helped, added two days after the dinner. It is the only blank cost on
#   that dinner.
#
# The answers for the other dinners are not in yet, and those dinners
# keep their blank costs. One of them is the dinner of 2025-07-06: it has a
# second blank cost, of a cook from another household, so it still waits
# after this.
#
# A blank cost and a No cost both add $0.00, so this moves no money; it
# changes what the meal page shows ("No cost" instead of a cost still to
# come) and lets the dinners settle. So a dinner that is not as expected
# is skipped and printed, and the deploy goes on: a cost entered since,
# a dinner settled since, or a dinner that does not hold exactly one cost
# that matches. With no meal on a date (any database but production)
# nothing matches, which is not an error. With this migration's audit rows
# there, it ran already, and it says so.
#
# Plain SQL, like migration 20261012120000 and for the same reasons. Each
# change gets the audit row a save would write ({"no_cost": [false,
# true]}), with no person and no username and this migration in the
# comment, so the meal history says "Automatic fix". updated_at moves on
# the meals, so the calendar's cache version moves.
#
# Runs in its own transaction and tries again on a conflict, like
# 20261010130000. down takes No cost off exactly the costs it marked,
# unless one changed since.
class MarkCostsTheCooksSaidWereNothing < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  BY = 'Automatic fix (migration 20261013120300).'
  COMMENT = "#{BY} Marked this blank cost No cost. The cook said they spent nothing.".freeze
  # The blank cost of a cook who lives with a cook who entered a cost.
  SAME_HOUSEHOLD = [Date.new(2024, 6, 30), Date.new(2024, 8, 8), Date.new(2025, 7, 6), Date.new(2025, 8, 31),
                    Date.new(2026, 3, 12), Date.new(2026, 4, 16), Date.new(2026, 5, 28), Date.new(2026, 10, 4)].freeze
  # The one blank cost on the dinner.
  ONLY_BLANK = [Date.new(2024, 11, 3)].freeze
  ATTEMPTS = 5

  Found = Struct.new(:date, :meal_id, :settled, :bill_ids)
  # One audit row this migration wrote, read back by down.
  Marked = Struct.new(:audit_id, :bill_id, :meal_id, :at)

  def up
    with_retry { connection.transaction { fix } }.each { |line| say line }
  end

  def down
    with_retry { connection.transaction { undo } }.each { |line| say line }
  end

  private

  # Returns the lines to print.
  def fix
    return ['This migration marked the costs already: nothing to mark.'] if done?

    found = lock_meals(SAME_HOUSEHOLD + ONLY_BLANK).map { |meal| find(meal) }
    return ['No meal on any of these dates: nothing to mark.'] if found.empty?

    marked, skipped = found.partition { |row| !row.settled && row.bill_ids.size == 1 }
    now = Time.current.utc
    mark(marked, now) unless marked.empty?
    marked.map { |row| "#{row.date}  marked the blank cost No cost" } + skipped.map { |row| skip_line(row) }
  end

  def done?
    connection.select_value(<<~SQL.squish).to_i.positive?
      SELECT COUNT(*) FROM audits WHERE auditable_type = 'Bill' AND comment = #{connection.quote(COMMENT)}
    SQL
  end

  # The meals on those dates, locked in id order, the order every meal
  # write uses.
  def lock_meals(dates)
    connection.select_rows(<<~SQL.squish)
      SELECT id, date, reconciliation_id FROM meals
      WHERE date IN (#{dates.map { |date| connection.quote(date) }.join(', ')})
      ORDER BY id
      FOR UPDATE
    SQL
  end

  def find(meal)
    id, date, reconciliation_id = meal
    date = date.to_date
    Found.new(date, id, !reconciliation_id.nil?, connection.select_values(<<~SQL.squish))
      SELECT bills.id FROM bills
      JOIN residents cook ON cook.id = bills.resident_id
      WHERE bills.meal_id = #{Integer(id)} AND bills.amount = 0 AND NOT bills.no_cost
        #{same_household(id) if SAME_HOUSEHOLD.include?(date)}
      ORDER BY bills.id
    SQL
  end

  # Another cook on the same dinner, of the same unit, entered a cost.
  def same_household(meal_id)
    <<~SQL.squish
      AND EXISTS (SELECT 1 FROM bills paid JOIN residents payer ON payer.id = paid.resident_id
                  WHERE paid.meal_id = #{Integer(meal_id)} AND paid.amount > 0 AND NOT paid.no_cost
                    AND payer.unit_id = cook.unit_id AND payer.id <> cook.id)
    SQL
  end

  def skip_line(row)
    why = if row.settled then 'the dinner is settled'
          elsif row.bill_ids.empty? then 'no blank cost matches (one may have been entered since)'
          else "#{row.bill_ids.size} blank costs match, not 1"
          end
    "#{row.date}  skipped: #{why}"
  end

  def mark(rows, now)
    ids = rows.map { |row| Integer(row.bill_ids.first) }
    connection.execute(<<~SQL.squish)
      INSERT INTO audits (auditable_type, auditable_id, associated_type, associated_id, action,
                          audited_changes, version, comment, username, request_uuid, created_at)
      SELECT 'Bill', bills.id, 'Meal', bills.meal_id, 'update', '{"no_cost": [false, true]}'::jsonb,
             COALESCE((SELECT MAX(audits.version) FROM audits
                       WHERE audits.auditable_type = 'Bill' AND audits.auditable_id = bills.id), 0) + 1,
             #{connection.quote(COMMENT)}, NULL, #{connection.quote(SecureRandom.uuid)}, #{connection.quote(now)}
      FROM bills WHERE bills.id IN (#{ids.join(', ')})
      ORDER BY bills.id
    SQL
    set_no_cost(ids, true, now)
    touch_meals(rows.map(&:meal_id), now)
  end

  def set_no_cost(ids, value, now)
    connection.execute(<<~SQL.squish)
      UPDATE bills SET no_cost = #{value}, updated_at = #{connection.quote(now)} WHERE id IN (#{ids.join(', ')})
    SQL
  end

  def touch_meals(meal_ids, now)
    ids = meal_ids.map { |id| Integer(id) }.join(', ')
    connection.execute("UPDATE meals SET updated_at = #{connection.quote(now)} WHERE id IN (#{ids})")
  end

  # Returns the lines to print.
  def undo
    rows = connection.select_rows(<<~SQL.squish).map { |row| Marked.new(*row) }
      SELECT audits.id, audits.auditable_id, audits.associated_id, audits.created_at FROM audits
      WHERE audits.auditable_type = 'Bill' AND audits.comment = #{connection.quote(COMMENT)}
      ORDER BY audits.auditable_id
    SQL
    return ['This migration marked no cost: nothing to take back.'] if rows.empty?

    connection.execute("SELECT id FROM meals WHERE id IN (#{rows.map { |row| Integer(row.meal_id) }.join(', ')}) " \
                       'ORDER BY id FOR UPDATE')
    rows.each { |row| unchanged!(row) }
    now = Time.current.utc
    set_no_cost(rows.map { |row| Integer(row.bill_id) }, false, now)
    touch_meals(rows.map(&:meal_id), now)
    connection.execute("DELETE FROM audits WHERE id IN (#{rows.map { |row| Integer(row.audit_id) }.join(', ')})")
    ["Took No cost off #{rows.size} cost(s)."]
  end

  # Taking No cost off a cost that changed since would undo that change.
  def unchanged!(row)
    audit_id = row.audit_id
    bill_id = row.bill_id
    at = row.at
    same = connection.select_value(<<~SQL.squish).to_i.positive?
      SELECT COUNT(*) FROM bills
      JOIN meals ON meals.id = bills.meal_id AND meals.reconciliation_id IS NULL
      WHERE bills.id = #{Integer(bill_id)} AND bills.no_cost AND bills.updated_at = #{connection.quote(at)}
        AND NOT EXISTS (SELECT 1 FROM audits later WHERE later.auditable_type = 'Bill'
                        AND later.auditable_id = #{Integer(bill_id)} AND later.id > #{Integer(audit_id)})
    SQL
    return if same

    raise "Cost #{bill_id} changed, or its dinner was settled, after migration 20261013120300, so taking No cost " \
          'off would undo that. Nothing was changed.'
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
