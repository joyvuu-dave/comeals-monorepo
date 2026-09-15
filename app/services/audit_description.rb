# typed: true
# frozen_string_literal: true

# Turns an audited change row into the sentence the meal page's history
# modal shows ("102 - Jane added as cook", "Meal closed"). Lifted out of
# ApplicationHelper, where audit parsing sat next to view formatting and
# ran its own queries from a view-layer module (#51).
#
# An audit row names records by id, and the record (or its create audit,
# when the record is gone) is the only way back to a resident's name. So
# a describer is built for a whole list of rows and loads what they name
# up front, one query per table: the bills and attendance rows that
# update rows point at, the create audits of those that are gone, and
# every resident any row names. Describing a row then reads nothing
# (#84: one to three queries per row made a long history a few hundred
# queries for one modal).
class AuditDescription
  include ActiveSupport::NumberHelper

  def self.describe(audit)
    self.for([audit]).describe(audit)
  end

  def self.for(audits)
    new(audits)
  end

  def initialize(audits)
    rows = audits.to_a
    @bill_cooks = cook_ids(Bill, rows, 'Bill')
    @attendance_residents = cook_ids(MealResident, rows, 'MealResident')
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

  # The resident id each update row's record points at, by record id:
  # from the record while it exists, and from the record's own create
  # audit once it is gone. A record neither has is left out.
  def cook_ids(model, rows, auditable_type)
    ids = rows.filter_map { |row| row.auditable_id if row.auditable_type == auditable_type && row.action == 'update' }
    return {} if ids.empty?

    from_records = model.where(id: ids).pluck(:id, :resident_id).to_h
    gone = ids - from_records.keys
    return from_records if gone.empty?

    from_trail = Audited::Audit.where(auditable_type: auditable_type, auditable_id: gone, action: 'create')
                               .to_h { |audit| [audit.auditable_id, audit.audited_changes['resident_id']] }
    from_records.merge(from_trail)
  end

  # Every resident id the rows name: in a create or destroy row's
  # changes, or through the record an update row points at.
  def named_resident_ids(rows)
    from_changes = rows.filter_map do |row|
      row.audited_changes['resident_id'] if %w[Bill MealResident Guest].include?(row.auditable_type)
    end
    (from_changes + @bill_cooks.values + @attendance_residents.values).compact.uniq
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

    if %w[create destroy].include?(audit.action)
      name = name_or_unknown(resident(changes['resident_id']))
      return "#{name} added as cook" if audit.action == 'create'

      return "#{name} removed as cook"
    end

    cook_name = name_or_unknown(resident(@bill_cooks[audit.auditable_id]))

    if changes['amount'].nil?
      if changes['no_cost'].instance_of?(Array)
        return "Bill for #{cook_name} no longer marked as no cost" unless changes['no_cost'][1] == true

        return "Bill for #{cook_name} marked as no cost"
      end
      return 'unknown bill changed'
    end

    if audit.action == 'update'
      msg = "Bill for #{cook_name} " \
            "changed from #{number_to_currency(changes['amount'][0])} " \
            "to #{number_to_currency(changes['amount'][1])}"
      if changes['no_cost'].instance_of?(Array)
        msg += changes['no_cost'][1] == true ? ' and marked as no cost' : ' and no longer marked as no cost'
      end
      return msg
    end

    fallback_description(audit)
  end

  def describe_meal_resident(audit) # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity --audit change parsing with many attribute branches
    changes = audit.audited_changes
    resident_id = audit.action == 'update' ? @attendance_residents[audit.auditable_id] : changes['resident_id']
    name = name_or_unknown(resident(resident_id))

    return "#{name} added" if audit.action == 'create'
    return "#{name} removed" if audit.action == 'destroy'

    if audit.action == 'update'
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

      return fallback_description(audit)
    end

    fallback_description(audit)
  end

  def describe_guest(audit)
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
end
