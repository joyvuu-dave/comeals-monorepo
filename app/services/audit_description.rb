# frozen_string_literal: true

# Turns an audited change row into the sentence the meal page's history
# modal shows ("102 - Jane added as cook", "Meal closed"). Lifted out of
# ApplicationHelper, where audit parsing sat next to view formatting and
# ran its own queries from a view-layer module (#51).
#
# Runs queries on purpose: an audit row names records by id, and the
# record (or its create-audit trail, when the record is gone) is the
# only way back to a resident's name.
class AuditDescription
  include ActiveSupport::NumberHelper

  def self.describe(audit)
    new.describe(audit)
  end

  def describe(audit)
    return describe_meal(audit) if audit.auditable_type == 'Meal'
    return describe_bill(audit) if audit.auditable_type == 'Bill'
    return describe_meal_resident(audit) if audit.auditable_type == 'MealResident'

    describe_guest(audit) if audit.auditable_type == 'Guest'
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

  # The resident an audit row was originally about, recovered from the
  # row's own create audit — used when the record itself is gone.
  def resident_from_audit_trail(auditable_type, auditable_id)
    create_audit = Audited::Audit.find_by(
      auditable_type: auditable_type,
      auditable_id: auditable_id,
      action: 'create'
    )
    Resident.find_by(id: create_audit&.audited_changes&.dig('resident_id'))
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

  def describe_bill(audit) # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity, Metrics/MethodLength --audit change parsing with many attribute branches
    changes = audit.audited_changes

    if %w[create destroy].include?(audit.action)
      name = name_or_unknown(Resident.find_by(id: changes['resident_id']))
      return "#{name} added as cook" if audit.action == 'create'

      return "#{name} removed as cook"
    end

    bill = Bill.find_by(id: audit.auditable_id)
    cook_name = if bill&.resident.present?
                  short_name(bill.resident.name)
                else
                  name_or_unknown(resident_from_audit_trail('Bill', audit.auditable_id))
                end

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

  def describe_meal_resident(audit) # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity --audit change parsing with many attribute branches
    changes = audit.audited_changes
    resident = if audit.action == 'update'
                 MealResident.find_by(id: audit.auditable_id)&.resident ||
                   resident_from_audit_trail('MealResident', audit.auditable_id)
               else
                 Resident.find_by(id: changes['resident_id'])
               end

    name = name_or_unknown(resident)

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
    name = name_or_unknown(Resident.find_by(id: changes['resident_id']))

    verb = { 'create' => 'added', 'destroy' => 'removed' }[audit.action]
    return fallback_description(audit) if verb.nil?

    case changes['vegetarian']
    when true then "Veg guest of #{name} #{verb}"
    when false then "Omnivore guest of #{name} #{verb}"
    else fallback_description(audit)
    end
  end
end
