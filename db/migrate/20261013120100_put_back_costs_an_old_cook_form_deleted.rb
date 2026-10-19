# frozen_string_literal: true

# Puts back the cook costs of one dinner (BBQ), which an old version of
# the cook form deleted, and puts the receipt it saved there instead on
# the dinner it was for, a dinner a few days later (PASTA). Then works out
# settlement 6, which holds both dinners, again. One of the history fixes
# the owner decided on 2026-10-12, run during the deploy so no person has
# to do it by hand.
#
# A cook of the PASTA dinner saved the cook form of the BBQ dinner by
# mistake. The cook form of that time replaced the whole list of cooks
# (issue #7), so the BBQ dinner's costs were deleted with no audit row,
# and the PASTA dinner's two cooks were saved there, one of them with the
# receipt typed for the PASTA dinner (RECEIPT). Later the PASTA dinner's
# other cook typed a cost on the PASTA dinner (NOTHING). The owner asked
# the cooks (2026-10-12): the BBQ dinner's cooks spent what they typed,
# and the PASTA dinner cost RECEIPT, which its first cook spent; the other
# cook spent nothing. So the BBQ dinner gets its costs back, with a zero
# one as No cost, and loses the two the form saved there; on the PASTA
# dinner the first cook gets RECEIPT and the other cook is No cost. The
# same form also deleted some empty cook slots from the PASTA dinner.
# They stay deleted: the owner confirmed its cooks were the two who have
# costs on it now.
#
# The rows are found by what is true of them, and every fact is checked
# under the meals' row locks before anything is written: both dinners
# are in the same settlement; the BBQ dinner has exactly two costs,
# RECEIPT and zero, of the two cooks who have zero and NOTHING on the
# PASTA dinner, and nothing else; the deleted costs are the bills whose
# create row names the BBQ dinner and that have no row and no delete row,
# one for each amount in DELETED, for other cooks, whose last saved
# amounts are those in DELETED. Each deleted cost comes back with its old
# id, so its old audit rows name it again, and with the time of its
# create row. This moves money, so any other state stops the deploy and
# changes nothing: a person looks first. Two states are not errors. With
# no meal on BBQ (any database but production) there is nothing to do.
# With this migration's audit rows there, it ran already: nobody else can
# change a settled dinner's costs.
#
# The settlement is worked out again with Settlement#correct!, exactly as
# migration 20261012120400 does, for the reasons given there. The rows
# change inside correct!, with the repair bypass on for those statements.
# Each change gets the audit row a save would write, with no person and
# no username and this migration in the comment, so the meal history
# says "Automatic fix". updated_at moves on both meals, so the calendar's
# cache version moves.
#
# Runs in its own transaction and tries again on a conflict, like
# 20261010130000. down puts every cost it changed back as it was, unless
# one changed since, and works the settlement out again with a correction
# of its own that says why.
class PutBackCostsAnOldCookFormDeleted < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  BY = 'Automatic fix (migration 20261013120100).'
  COMMENT = "#{BY} Put back the costs an old cook form deleted from the BBQ dinner of 2019-09-02, and moved " \
            'the $49.50 it saved there to the pasta dinner of 2019-09-05, as the cooks said.'.freeze
  BBQ = Date.new(2019, 9, 2)
  PASTA = Date.new(2019, 9, 5)
  RECEIPT = BigDecimal('49.50')
  NOTHING = BigDecimal('47.58')
  DELETED = [BigDecimal('0'), BigDecimal('15'), BigDecimal('70')].freeze
  ATTEMPTS = 5

  MealRow = Struct.new(:id, :date, :reconciliation_id)
  CostRow = Struct.new(:id, :resident_id, :amount, :no_cost, :community_id, :created_at)
  # Who is who: the cook whose RECEIPT is on the BBQ dinner and the other
  # cook the form saved there, each with their cost on both dinners.
  Cooks = Struct.new(:receipt_on_bbq, :receipt_on_pasta, :other_on_bbq, :other_on_pasta)
  # One audit row: to write (no id or time yet), or written and read back.
  AuditRow = Struct.new(:bill_id, :meal_id, :action, :changes, :audit_id, :at)
  # When this run writes, and the request id its audit rows share.
  Stamp = Struct.new(:now, :request)

  def up
    with_retry { connection.transaction { fix } }.each { |line| say line }
  end

  def down
    with_retry { connection.transaction { undo } }.each { |line| say line }
  end

  private

  # Returns the lines to print.
  def fix
    bbq, pasta = lock_meals
    return ["No meal on #{BBQ}: nothing to put back."] if bbq.nil?
    return ['This migration changed the costs of both dinners already: nothing to change.'] if done?

    deleted = deleted_costs(bbq.id)
    check_meals(bbq, pasta)
    cooks = check_costs(bbq, pasta, deleted)
    stamp = Stamp.new(Time.current.utc, SecureRandom.uuid)
    corrected = correct(bbq) { write_fix(bbq, pasta, cooks, deleted, stamp) }
    touch_meals([bbq.id, pasta.id], stamp.now)
    ["Put back #{deleted.size} costs on #{BBQ} (#{deleted.map { |cost| money(cost.amount) }.join(', ')}), " \
     "and moved the #{money(RECEIPT)} receipt to #{PASTA}, where the other cook's #{money(NOTHING)} is now No cost.",
     "Worked out settlement #{bbq.reconciliation_id} again: #{corrected.lines.count} balance(s) changed."]
  end

  # Both meals, locked in id order, the order every meal write uses.
  def lock_meals
    rows = connection.select_rows(<<~SQL.squish).map { |row| MealRow.new(*row) }
      SELECT id, date, reconciliation_id FROM meals
      WHERE date IN (#{connection.quote(BBQ)}, #{connection.quote(PASTA)})
      ORDER BY id
      FOR UPDATE
    SQL
    [rows.find { |meal| meal.date.to_date == BBQ }, rows.find { |meal| meal.date.to_date == PASTA }]
  end

  def costs_on(meal_id)
    connection.select_rows(<<~SQL.squish).map { |row| CostRow.new(*row) }
      SELECT id, resident_id, amount, no_cost, community_id, created_at FROM bills
      WHERE meal_id = #{Integer(meal_id)} ORDER BY id
    SQL
  end

  # The costs whose create row names the BBQ dinner, which have no row now
  # and no delete row: the form of issue #7 deleted them with no record.
  # Each with its last saved amount and the time of its create row.
  def deleted_costs(meal_id)
    rows = connection.select_rows(<<~SQL.squish)
      SELECT created.auditable_id, (created.audited_changes->>'resident_id')::bigint,
             (created.audited_changes->>'community_id')::bigint, created.created_at
      FROM audits created
      WHERE created.auditable_type = 'Bill' AND created.action = 'create'
        AND (created.audited_changes->>'meal_id')::bigint = #{Integer(meal_id)}
        AND NOT EXISTS (SELECT 1 FROM bills WHERE bills.id = created.auditable_id)
        AND NOT EXISTS (SELECT 1 FROM audits deleted WHERE deleted.auditable_type = 'Bill'
                        AND deleted.auditable_id = created.auditable_id AND deleted.action = 'destroy')
      ORDER BY created.auditable_id
    SQL
    rows.map do |id, resident_id, community_id, created_at|
      CostRow.new(id, resident_id, last_amount(id), nil, community_id, created_at)
    end
  end

  # The amount in the newest audit row of a bill that names one. Rows from
  # before 2026 hold amount_cents; later ones hold amount as text. A change
  # holds [old, new].
  def last_amount(bill_id)
    changes = connection.select_value(<<~SQL.squish)
      SELECT audited_changes FROM audits
      WHERE auditable_type = 'Bill' AND auditable_id = #{Integer(bill_id)}
        AND (audited_changes ? 'amount' OR audited_changes ? 'amount_cents')
      ORDER BY id DESC LIMIT 1
    SQL
    changes = JSON.parse(changes)
    return BigDecimal(Array(changes['amount']).last.to_s) if changes.key?('amount')

    BigDecimal(Array(changes['amount_cents']).last.to_s) / 100
  end

  # This migration's own audit rows are there. Nobody else can change a
  # settled dinner's costs, so no one did it by hand.
  def done?
    connection.select_value(<<~SQL.squish).to_i.positive?
      SELECT COUNT(*) FROM audits WHERE auditable_type = 'Bill' AND comment = #{connection.quote(COMMENT)}
    SQL
  end

  def check_meals(bbq, pasta)
    refuse("there is no meal on #{PASTA}") if pasta.nil?
    refuse("the dinner of #{BBQ} is not settled") if bbq.reconciliation_id.nil?
    refuse('the two dinners are not in the same settlement') unless pasta.reconciliation_id == bbq.reconciliation_id
  end

  def check_costs(bbq, pasta, deleted)
    on_bbq = costs_on(bbq.id)
    on_pasta = costs_on(pasta.id)
    receipt = on_bbq.find { |cost| amount_is?(cost, RECEIPT) }
    other = (on_bbq - [receipt]).first
    refuse("the dinner of #{BBQ} has #{on_bbq.size} cost(s), not 2") unless on_bbq.size == 2
    refuse("its costs are not #{money(RECEIPT)} and $0.00") unless receipt && amount_is?(other, 0)
    cooks = Cooks.new(receipt, own(on_pasta, receipt), other, own(on_pasta, other))
    unless on_pasta.size == 2 && amount_is?(cooks.receipt_on_pasta, 0) && amount_is?(cooks.other_on_pasta, NOTHING)
      refuse("the dinner of #{PASTA} does not have the same two cooks at $0.00 and #{money(NOTHING)}")
    end
    check_deleted(deleted, [receipt.resident_id, other.resident_id])
    cooks
  end

  def check_deleted(deleted, cooks_now)
    refuse("#{deleted.size} deleted cost(s) were found, not 3") unless deleted.size == 3
    amounts = deleted.map(&:amount).sort
    refuse("the deleted costs were #{amounts.map { |amount| money(amount) }.join(', ')}") unless amounts == DELETED
    others = deleted.map { |cost| Integer(cost.resident_id) } - cooks_now.map { |id| Integer(id) }
    refuse('the deleted costs are not of three other cooks') unless others.uniq.size == 3
  end

  # The cost of the same cook on the other meal, or nil.
  def own(costs, cost)
    costs.find { |row| Integer(row.resident_id) == Integer(cost.resident_id) } if cost
  end

  def amount_is?(cost, amount)
    !cost.nil? && BigDecimal(cost.amount.to_s) == BigDecimal(amount.to_s) && !yes?(cost.no_cost)
  end

  # The settlement of both dinners, worked out again with the block's
  # change inside it. Returns the correction.
  def correct(bbq, &)
    reload_models
    reconciliation = Reconciliation.find(bbq.reconciliation_id)
    Settlement.new(reconciliation).correct!(reason: reason) { with_settled_writes(&) }
  end

  def reason
    "An old cook form deleted the three costs of the BBQ dinner of #{BBQ} and saved the $49.50 receipt of the " \
      "pasta dinner of #{PASTA} there. These numbers use the costs the cooks gave: the three back, the receipt on " \
      "the pasta dinner, and the pasta dinner's other cook at No cost."
  end

  def write_fix(bbq, pasta, cooks, deleted, stamp)
    [cooks.receipt_on_bbq, cooks.other_on_bbq].each do |cost|
      write_audit(AuditRow.new(cost.id, bbq.id, 'destroy', bill_changes(cost, bbq.id)), stamp)
    end
    connection.execute("DELETE FROM bills WHERE id IN (#{cooks.receipt_on_bbq.id.to_i}, #{cooks.other_on_bbq.id.to_i})")
    deleted.each do |cost|
      put_back = cost.dup.tap { |row| row.no_cost = BigDecimal(row.amount.to_s).zero? }
      insert_bill(put_back, bbq.id, stamp.now)
      write_audit(AuditRow.new(cost.id, bbq.id, 'create', bill_changes(put_back, bbq.id)), stamp)
    end
    set_cost(cooks.receipt_on_pasta, RECEIPT, false, pasta.id, stamp)
    set_cost(cooks.other_on_pasta, BigDecimal('0'), true, pasta.id, stamp)
  end

  # The bill's audited columns, the way audited writes them for a create
  # or a delete: the amount as text, as BigDecimal#as_json gives it.
  def bill_changes(cost, meal_id)
    { 'amount' => BigDecimal(cost.amount.to_s).to_s, 'meal_id' => Integer(meal_id),
      'no_cost' => yes?(cost.no_cost), 'resident_id' => Integer(cost.resident_id),
      'community_id' => Integer(cost.community_id) }
  end

  def insert_bill(cost, meal_id, now)
    values = [Integer(cost.id), Integer(meal_id), Integer(cost.resident_id), BigDecimal(cost.amount.to_s),
              yes?(cost.no_cost), Integer(cost.community_id), cost.created_at, now]
    connection.execute(<<~SQL.squish)
      INSERT INTO bills (id, meal_id, resident_id, amount, no_cost, community_id, created_at, updated_at)
      VALUES (#{values.map { |value| connection.quote(value) }.join(', ')})
    SQL
  end

  # Sets one cost's amount and No cost, with the update row a save writes:
  # only the columns that changed.
  def set_cost(cost, amount, no_cost, meal_id, stamp)
    changes = {}
    was = BigDecimal(cost.amount.to_s)
    changes['amount'] = [was.to_s, amount.to_s] unless was == amount
    changes['no_cost'] = [yes?(cost.no_cost), no_cost] unless yes?(cost.no_cost) == no_cost
    connection.execute(<<~SQL.squish)
      UPDATE bills SET amount = #{connection.quote(amount)}, no_cost = #{connection.quote(no_cost)},
                       updated_at = #{connection.quote(stamp.now)}
      WHERE id = #{Integer(cost.id)}
    SQL
    write_audit(AuditRow.new(cost.id, meal_id, 'update', changes), stamp)
  end

  def write_audit(row, stamp)
    connection.execute(<<~SQL.squish)
      INSERT INTO audits (auditable_type, auditable_id, associated_type, associated_id, action,
                          audited_changes, version, comment, username, request_uuid, created_at)
      VALUES ('Bill', #{Integer(row.bill_id)}, 'Meal', #{Integer(row.meal_id)}, #{connection.quote(row.action)},
              #{connection.quote(row.changes.to_json)}::jsonb,
              COALESCE((SELECT MAX(version) FROM audits
                        WHERE auditable_type = 'Bill' AND auditable_id = #{Integer(row.bill_id)}), 0) + 1,
              #{connection.quote(COMMENT)}, NULL, #{connection.quote(stamp.request)}, #{connection.quote(stamp.now)})
    SQL
  end

  def touch_meals(meal_ids, now)
    ids = meal_ids.map { |id| Integer(id) }.join(', ')
    connection.execute("UPDATE meals SET updated_at = #{connection.quote(now)} WHERE id IN (#{ids})")
  end

  # Returns the lines to print.
  def undo
    rows = connection.select_rows(<<~SQL.squish).map { |row| AuditRow.new(*row) }
      SELECT auditable_id, associated_id, action, audited_changes, id, created_at FROM audits
      WHERE auditable_type = 'Bill' AND comment = #{connection.quote(COMMENT)}
      ORDER BY id
    SQL
    return ['This migration changed no cost: nothing to put back.'] if rows.empty?

    bbq, pasta = lock_meals
    check_unchanged(rows)
    now = Time.current.utc
    reload_models
    corrected = Settlement.new(Reconciliation.find(bbq.reconciliation_id))
                          .correct!(reason: undo_reason) { with_settled_writes { write_undo(rows, now) } }
    touch_meals([bbq.id, pasta.id], now)
    connection.execute("DELETE FROM audits WHERE id IN (#{rows.map { |row| Integer(row.audit_id) }.join(', ')})")
    ['Put the costs of both dinners back as they were before this migration.',
     "Worked out settlement #{bbq.reconciliation_id} again: #{corrected.lines.count} balance(s) changed."]
  end

  # Every cost this changed, as this left it. Otherwise putting the old
  # costs back would undo a later change.
  def check_unchanged(rows)
    rows.each do |row|
      next if row.action == 'destroy'

      same = connection.select_value(<<~SQL.squish).to_i.positive?
        SELECT COUNT(*) FROM bills
        WHERE id = #{Integer(row.bill_id)} AND updated_at = #{connection.quote(row.at)}
          AND NOT EXISTS (SELECT 1 FROM audits later WHERE later.auditable_type = 'Bill'
                          AND later.auditable_id = #{Integer(row.bill_id)} AND later.id > #{Integer(row.audit_id)})
      SQL
      next if same

      raise "Cost #{row.bill_id} changed after migration 20261013120100, so putting the old costs back would undo " \
            'that change. Nothing was changed.'
    end
  end

  def write_undo(rows, now)
    rows.reverse_each do |row|
      changes = JSON.parse(row.changes)
      case row.action
      when 'create' then connection.execute("DELETE FROM bills WHERE id = #{Integer(row.bill_id)}")
      when 'destroy' then insert_bill(old_cost(row.bill_id, changes), row.meal_id, now)
      else restore(row.bill_id, changes, now)
      end
    end
  end

  def old_cost(bill_id, changes)
    first = connection.select_value(<<~SQL.squish)
      SELECT MIN(created_at) FROM audits WHERE auditable_type = 'Bill' AND auditable_id = #{Integer(bill_id)}
    SQL
    CostRow.new(bill_id, changes['resident_id'], BigDecimal(changes['amount']), changes['no_cost'],
                changes['community_id'], first)
  end

  def restore(bill_id, changes, now)
    sets = []
    sets << "amount = #{connection.quote(BigDecimal(changes['amount'].first))}" if changes.key?('amount')
    sets << "no_cost = #{connection.quote(changes['no_cost'].first)}" if changes.key?('no_cost')
    connection.execute(<<~SQL.squish)
      UPDATE bills SET #{sets.join(', ')}, updated_at = #{connection.quote(now)}
      WHERE id = #{Integer(bill_id)}
    SQL
  end

  def undo_reason
    'Migration 20261013120100 was rolled back, so the costs of the BBQ dinner of 2019-09-02 and the pasta dinner ' \
      'of 2019-09-05 are as they were before it. These numbers use those costs again.'
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
    raise "Migration 20261013120100 expected the costs an old cook form left on the dinners of #{BBQ} and " \
          "#{PASTA}, but #{why}. Nothing was changed. Look at both dinners, then fix the data or this migration."
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
