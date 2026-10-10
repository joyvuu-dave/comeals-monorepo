# typed: true
# frozen_string_literal: true

# Turns an audited change row into the sentence the meal page's history
# modal shows ("102 - Jane added as cook", "Meal closed"). Lifted out of
# ApplicationHelper, where audit parsing sat next to view formatting and
# ran its own queries from a view-layer module (#51).
#
# An update row of a bill, an attendance row or a guest names no
# resident unless it changed one. The record's own history is the only
# way back to whose it was. So a describer is built for a whole list of
# rows and loads what they name up front: the history of every record an
# update row points at, in one query, and every resident any row names,
# in one more. Describing a row then reads nothing (#84: one to three
# queries per row made a long history a few hundred queries for one
# modal).
class AuditDescription
  include ActiveSupport::NumberHelper

  # The records whose update rows name their resident (a bill's cook, an
  # attendance row's person, a guest's host) only through the record.
  NAMED_THROUGH_HISTORY = %w[Bill MealResident Guest].freeze

  def self.describe(audit)
    self.for([audit]).describe(audit)
  end

  def self.for(audits)
    new(audits)
  end

  def initialize(audits)
    rows = audits.to_a
    @named_before, @amount_before = before_each_update(rows)
    @residents = Resident.where(id: named_resident_ids(rows)).index_by(&:id)
  end

  def describe(audit)
    return describe_meal(audit) if audit.auditable_type == 'Meal'
    return describe_bill(audit) if audit.auditable_type == 'Bill'
    return describe_meal_resident(audit) if audit.auditable_type == 'MealResident'

    return describe_guest(audit) if audit.auditable_type == 'Guest'

    fallback_description(audit)
  end

  private

  def short_name(name)
    ResidentNameShortener.short(name)
  end

  # The shortened resident name, or 'unknown' when the resident is gone
  # and the audit trail cannot recover them.
  def name_or_unknown(resident)
    resident.present? ? short_name(resident.name) : 'unknown'
  end

  # What we say about a change no branch above recognized.
  def fallback_description(audit)
    "#{audit.auditable_type}, #{audit.action}"
  end

  # Two lists, by audit id, of what each update row's record held just
  # before that row was written. The first is the resident it named: a
  # bill's cook, an attendance row's person, a guest's host. The second is
  # a bill's amount, in dollars. Read from the record's own history, in
  # order: what its create row says, then each change after it.
  # Not from the record as it is now, because a later change would put the
  # new resident's name, or the new amount, on an older line. Until
  # 2026-10-10 an admin could change a bill's cook in place
  # (Bill::COOK_AND_MEAL_FIXED), and a guest's host can still change. A
  # record with no create row names no one here, and is shown as
  # 'unknown': the app has audited these records from the start, so only a
  # record written outside the app has none.
  #
  # One query for every record of the three kinds. Each kind has its own
  # ids, because a bill and an attendance row often share an id.
  def before_each_update(rows)
    updates = rows.select { |row| NAMED_THROUGH_HISTORY.include?(row.auditable_type) && row.action == 'update' }
    return [{}, {}] if updates.empty?

    trail = updates.group_by(&:auditable_type)
                   .map { |type, typed| Audited::Audit.where(auditable_type: type, auditable_id: typed.map(&:auditable_id)) }
                   .reduce(:or)
                   .where(action: %w[create update])
                   .order(:version, :id)
    walk(trail)
  end

  # In version order, which is each record's own order, then by id: two rows
  # of one record can share a version (374 bills in the production copy do),
  # and without the id PostgreSQL picks their order. Rows of different
  # records may mix: named_now and amount_now keep one value per record.
  def walk(trail)
    named_now = {}
    amount_now = {}
    trail.each_with_object([{}, {}]) do |audit, (named, amounts)|
      record = [audit.auditable_type, audit.auditable_id]
      changes = audit.audited_changes
      if audit.action == 'create'
        named_now[record] = changes['resident_id']
        amount_now[record] = created_amount(changes)
      else
        named[audit.id] = named_now[record]
        amounts[audit.id] = amount_now[record]
        named_now[record] = changes['resident_id'].last if changes['resident_id'].instance_of?(Array)
        amount = amount_change(changes)
        amount_now[record] = dollars(amount.last) if amount.instance_of?(Array)
      end
    end
  end

  # The amount a bill's create row gives it, in dollars, or nil. Rows
  # written before migration 20260326000001 hold whole cents
  # (amount_change says more).
  def created_amount(changes)
    return dollars(changes['amount']) if changes.key?('amount')

    cents = changes['amount_cents']
    BigDecimal(cents) / 100 if cents.is_a?(Integer)
  end

  # An amount as a row stores it (audited writes a decimal as text, like
  # "86.0"), as a BigDecimal, or nil when it is not a number.
  def dollars(value)
    BigDecimal(value.to_s, exception: false)
  end

  # Every resident id the rows name: in a create or destroy row's
  # changes, both sides of a change of resident in an update row, or
  # through the history of the record an update row points at.
  def named_resident_ids(rows)
    from_changes = rows.filter_map do |row|
      row.audited_changes['resident_id'] if NAMED_THROUGH_HISTORY.include?(row.auditable_type)
    end
    (from_changes.flatten + @named_before.values).compact.uniq
  end

  # The name of the resident an update row's record named just before
  # the row, or 'unknown'.
  def name_before(audit)
    name_or_unknown(resident(@named_before[audit.id]))
  end

  # "from Ann to Bob" for a row that changed the resident, or nil.
  def moved(changes)
    ids = changes['resident_id']
    return nil unless ids.instance_of?(Array)

    "from #{name_or_unknown(resident(ids.first))} to #{name_or_unknown(resident(ids.last))}"
  end

  def resident(id)
    @residents[id]
  end

  def describe_meal(audit) # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity --audit change parsing with many attribute branches
    return 'Meal record created' if audit.action == 'create'
    return 'Meal record deleted' if audit.action == 'destroy'

    if audit.action == 'update'
      changes = audit.audited_changes

      # Meal Opened / Closed
      if changes['closed'].instance_of?(Array)
        return 'Meal closed' if changes['closed'][1] == true
        return 'Meal opened' if changes['closed'][0] == true

        return fallback_description(audit)
      end

      # Meal Description Updated
      return 'Menu description updated' if changes['description'].present?

      # Extras Count Changed
      if changes['max'].instance_of?(Array)
        initial = changes['max'][0]
        final = changes['max'][1]

        # Extras set for first time
        return 'Extras count set' if initial.nil?

        # Extras value reset
        return 'Extras count cleared' if final.nil?

        # Extras count increased
        return "Extras count increased by #{final - initial}" if final > initial

        # Extras count decreased
        return "Extras count decreased by #{initial - final}" if initial > final

        # Shouldn't happen?
        return 'Extras count set'
      end

      # Meal added to Rotation
      return 'Meal assigned to a rotation' if changes['rotation_id'].present?

      # Other
      return fallback_description(audit)
    end

    fallback_description(audit) # Shouldn't happen?
  end

  def describe_bill(audit)
    changes = audit.audited_changes
    case audit.action
    when 'create' then "#{name_or_unknown(resident(changes['resident_id']))} added as cook"
    when 'destroy' then "#{name_or_unknown(resident(changes['resident_id']))} removed as cook"
    when 'update' then describe_bill_update(audit)
    else fallback_description(audit)
    end
  end

  # "Bill for Ann changed from $30.00 to $50.00", "Bill for Ann marked as
  # no cost", or both, joined by "and". A row that changed the cook
  # (possible until 2026-10-10, Bill::COOK_AND_MEAL_FIXED) starts "Bill
  # moved from Ann to Bob" instead, and any other change follows it.
  def describe_bill_update(audit)
    changes = audit.audited_changes
    amounts = amount_change(changes)
    what = [amounts && "changed from #{number_to_currency(amounts[0])} to #{number_to_currency(amounts[1])}",
            no_cost_change(audit, amounts.nil? ? @amount_before[audit.id] : nil)].compact
    move = moved(changes)
    return ["Bill moved #{move}", *what].join(' and ') if move
    return 'unknown bill changed' if what.empty?

    "Bill for #{name_before(audit)} #{what.join(' and ')}"
  end

  # "marked as no cost" or "no longer marked as no cost". When No cost
  # goes off on a bill that already had an amount, and the row does not
  # change the amount, the amount now counts, so the line says so: "no
  # longer marked as no cost, so the $86.00 now counts in the meal's
  # cost". Before April 2026 the meal page let a cost be typed into a row
  # marked No cost, and MealLedger leaves a no-cost bill out of the meal's
  # cost. Migration 20261010130000 turned No cost off on those bills, with
  # rows like this one. On a meal that was already settled, the migration
  # worked the settlement out again with the amount counted
  # (Settlement#correct!), so the line is true there too. `amount` is the
  # bill's amount just before the row, from its history, or nil.
  def no_cost_change(audit, amount)
    flags = audit.audited_changes['no_cost']
    return nil unless flags.instance_of?(Array)
    return 'marked as no cost' if flags[1] == true
    return 'no longer marked as no cost' unless amount&.positive?

    "no longer marked as no cost, so the #{number_to_currency(amount)} now counts in the meal's cost"
  end

  # The amount a bill row changed, as [from, to] in dollars, or nil when
  # it changed none. Until migration 20260326000001 the column was
  # amount_cents and held whole cents, and the audit rows written before
  # it still say so (6051 in production, 2017 to 2026-03). Those become
  # dollars here, as BigDecimal, so they read like every later row. A row
  # whose amount_cents is not a list of whole numbers is not read: the
  # column was a NOT NULL integer, so a real row never has that.
  def amount_change(changes)
    return changes['amount'] unless changes['amount'].nil?

    cents = changes['amount_cents']
    return nil unless cents.instance_of?(Array) && cents.all?(Integer)

    cents.map { |amount| BigDecimal(amount) / 100 }
  end

  def describe_meal_resident(audit)
    changes = audit.audited_changes
    case audit.action
    when 'create' then "#{name_or_unknown(resident(changes['resident_id']))} added"
    when 'destroy' then "#{name_or_unknown(resident(changes['resident_id']))} removed"
    when 'update' then describe_meal_resident_update(audit)
    else fallback_description(audit)
    end
  end

  def describe_meal_resident_update(audit) # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity --audit change parsing with many attribute branches
    changes = audit.audited_changes
    price = price_change(changes)
    # Nothing in the app changes the person on an attendance row, but
    # three old rows in production did (attendance row 8756, 2023-03-05).
    move = moved(changes)
    return ["Sign-up moved #{move}", price].compact.join(': ') if move

    name = name_before(audit)
    return "#{name}: #{price}" if price

    if changes['late'].instance_of?(Array)
      return "#{name} marked late" if changes['late'][0] == false && changes['late'][1] == true
      return "#{name} marked not late" if changes['late'][0] == true && changes['late'][1] == false

      return fallback_description(audit)
    end

    if changes['vegetarian'].instance_of?(Array)
      return "#{name} marked veg" if changes['vegetarian'][0] == false && changes['vegetarian'][1] == true
      return "#{name} marked not veg" if changes['vegetarian'][0] == true && changes['vegetarian'][1] == false

      return fallback_description(audit)
    end

    fallback_description(audit)
  end

  def describe_guest(audit)
    return describe_guest_update(audit) if audit.action == 'update'

    changes = audit.audited_changes
    name = name_or_unknown(resident(changes['resident_id']))

    verb = { 'create' => 'added', 'destroy' => 'removed' }[audit.action]
    return fallback_description(audit) if verb.nil?

    case changes['vegetarian']
    when true then "Veg guest of #{name} #{verb}"
    when false then "Omnivore guest of #{name} #{verb}"
    else fallback_description(audit)
    end
  end

  # "Guest of Ann moved to Bob", "Guest of Ann: Adult to Child", or both
  # from one save: "Guest of Ann moved to Bob: Adult to Child". Any other
  # change (nothing in the app writes one) falls back.
  def describe_guest_update(audit)
    changes = audit.audited_changes
    price = price_change(changes)
    hosts = changes['resident_id']
    unless hosts.instance_of?(Array)
      return fallback_description(audit) if price.nil?

      return "Guest of #{name_before(audit)}: #{price}"
    end

    sentence = "Guest of #{name_or_unknown(resident(hosts.first))} moved to #{name_or_unknown(resident(hosts.last))}"
    price ? "#{sentence}: #{price}" : sentence
  end

  # "Child to Adult", in the words every admin page uses, or nil when the
  # row did not change the price or holds something other than two whole
  # numbers (Multiplier.label takes only an Integer, and a history that
  # raises shows nothing at all).
  def price_change(changes)
    prices = changes['multiplier']
    return nil unless prices.instance_of?(Array) && prices.all?(Integer)

    from, to = prices
    "#{Multiplier.label(from)} to #{Multiplier.label(to)}"
  end
end
