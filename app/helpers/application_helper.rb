# frozen_string_literal: true

module ApplicationHelper
  include ActiveSupport::NumberHelper

  def category_helper(multiplier)
    return 'Child' if multiplier == 1
    return 'Adult' if multiplier == 2

    "#{multiplier / 2.to_f} Adult"
  end

  # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity --name disambiguation with multiple uniqueness checks
  # rubocop:disable Rails/HelperInstanceVariable --@resident_names is a memoized cache to avoid repeated DB queries
  def resident_name_helper(name)
    return '' if name.blank?

    first = name.split[0]
    last = name.split[1]

    @resident_names ||= Resident.pluck(:name)
    first_names = @resident_names.map { |n| n.split[0] }

    # Scenario #1: Name is just a first name (already unique)
    return name if last.nil?

    # Scenario #2: first name is unique
    return first if first_names.count(first) == 1

    # Scenario #3: first name is not unique --use last initial if
    # unique, otherwise fall back to full last name
    same_first = @resident_names.select { |n| n.split[0] == first }
    initial_unique = same_first.none? { |n| n != name && n.split[1]&.start_with?(last[0]) }
    initial_unique ? "#{first} #{last[0]}" : "#{first} #{last}"
  end
  # rubocop:enable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
  # rubocop:enable Rails/HelperInstanceVariable

  def resident_from_audit_trail(auditable_type, auditable_id)
    create_audit = Audited::Audit.find_by(
      auditable_type: auditable_type,
      auditable_id: auditable_id,
      action: 'create'
    )
    Resident.find_by(id: create_audit&.audited_changes&.dig('resident_id'))
  end

  def parse_audit(audit)
    return parse_meal_audit(audit) if audit.auditable_type == 'Meal'
    return parse_bill_audit(audit) if audit.auditable_type == 'Bill'
    return parse_meal_resident_audit(audit) if audit.auditable_type == 'MealResident'

    parse_guest_audit(audit) if audit.auditable_type == 'Guest'
  end

  def parse_meal_audit(audit) # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity --audit change parsing with many attribute branches
    return 'Meal record created' if audit.action == 'create'
    return 'Meal record deleted' if audit.action == 'destroy'

    if audit.action == 'update'
      changes = audit.audited_changes

      # Meal Opened / Closed
      if changes['closed'].instance_of?(Array)
        return 'Meal closed' if changes['closed'][1] == true
        return 'Meal opened' if changes['closed'][0] == true

        return "#{audit.auditable_type}, #{audit.action}"
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
        return "Extras count decreasesd by #{initial - final}" if initial > final

        # Shouldn't happen?
        return 'Extras count set'
      end

      # Meal added to Rotation
      return 'Meal assigned to a rotation' if changes['rotation_id'].present?

      # Other
      return "#{audit.auditable_type}, #{audit.action}"
    end

    "Meal, #{audit.action}" # Shouldn't happen?
  end

  def parse_bill_audit(audit) # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity, Metrics/MethodLength --audit change parsing with many attribute branches
    changes = audit.audited_changes

    if %w[create destroy].include?(audit.action)
      resident = Resident.find_by(id: changes['resident_id'])
      name = resident.present? ? resident_name_helper(resident.name) : 'unknown'
      return "#{name} added as cook" if audit.action == 'create'

      return "#{name} removed as cook"
    end

    bill = Bill.find_by(id: audit.auditable_id)
    cook_name = if bill&.resident.present?
                  resident_name_helper(bill.resident.name)
                else
                  resident = resident_from_audit_trail('Bill', audit.auditable_id)
                  resident.present? ? resident_name_helper(resident.name) : 'unknown'
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

    "#{audit.auditable_type}, #{audit.action}"
  end

  def parse_meal_resident_audit(audit) # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity --audit change parsing with many attribute branches
    changes = audit.audited_changes
    resident = if audit.action == 'update'
                 MealResident.find_by(id: audit.auditable_id)&.resident ||
                   resident_from_audit_trail('MealResident', audit.auditable_id)
               else
                 Resident.find_by(id: changes['resident_id'])
               end

    name = resident.present? ? resident_name_helper(resident.name) : 'unknown'

    return "#{name} added" if audit.action == 'create'
    return "#{name} removed" if audit.action == 'destroy'

    if audit.action == 'update'
      if changes['late'].instance_of?(Array)
        return "#{name} marked late" if changes['late'][0] == false && changes['late'][1] == true
        return "#{name} marked not late" if changes['late'][0] == true && changes['late'][1] == false

        return "#{audit.auditable_type}, #{audit.action}"
      end

      if changes['vegetarian'].instance_of?(Array)
        return "#{name} marked veg" if changes['vegetarian'][0] == false && changes['vegetarian'][1] == true
        return "#{name} marked not veg" if changes['vegetarian'][0] == true && changes['vegetarian'][1] == false

        return "#{audit.auditable_type}, #{audit.action}"
      end

      return "#{audit.auditable_type}, #{audit.action}"
    end

    "#{audit.auditable_type}, #{audit.action}"
  end

  def parse_guest_audit(audit)
    changes = audit.audited_changes
    resident = Resident.find_by(id: changes['resident_id'])
    name = resident.present? ? resident_name_helper(resident.name) : 'unknown'

    if audit.action == 'create'
      return "Veg guest of #{name} added" if changes['vegetarian'] == true
      return "Omnivore guest of #{name} added" if changes['vegetarian'] == false

      return "#{audit.auditable_type}, #{audit.action}"
    end

    if audit.action == 'destroy'
      return "Veg guest of #{name} removed" if changes['vegetarian'] == true
      return "Omnivore guest of #{name} removed" if changes['vegetarian'] == false

      return "#{audit.auditable_type}, #{audit.action}"
    end

    "#{audit.auditable_type}, #{audit.action}"
  end
end
