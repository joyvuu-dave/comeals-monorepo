# frozen_string_literal: true

# The settlement line items table, shared by the meal page and the
# resident statement (app/admin/meal.rb and app/admin/resident.rb).
# The two screens must render a charge identically, and they used to do
# it with two hand-synced copies — this is now the one place. The caller
# picks the first column: the meal page names the resident on each line,
# the resident statement names the meal.
class SettlementLinesTable < Arbre::Component
  builder_method :settlement_lines_table

  # Arbre passes builder options as a plain hash, not Ruby keywords.
  def build(lines, options = {})
    first_column = validated_first_column(options)

    if lines.empty?
      para 'No line items were recorded for this settlement.'
      return
    end

    table_for lines do
      case first_column
      when :resident
        column('Resident') { |charge| link_to charge.resident.name, admin_resident_path(charge.resident) }
      when :meal
        column('Meal') { |charge| link_to charge.meal.date, admin_meal_path(charge.meal) }
      end
      column('What') { |charge| MealCharge::KIND_LABELS.fetch(charge.kind) }
      column('Category') do |charge|
        price_category_label(charge.multiplier) unless charge.multiplier.nil?
      end
      column('Amount') { |charge| charge_amount_tag(charge) }
      # Only when this table has one: the column answers "why was the
      # credit smaller than the receipt", and with no capped cook in the
      # table it would be a blank column with no question.
      if lines.any?(&:subsidized?)
        column('Cook spent') do |charge|
          number_to_currency(charge.bill_amount) if charge.subsidized?
        end
      end
    end
  end

  private

  # Checked before the empty-lines return in build, so a bad symbol
  # raises on every render — not just the first one with real charge
  # lines (an empty-data render would otherwise pass silently).
  def validated_first_column(options)
    first_column = options.fetch(:first_column)
    return first_column if %i[resident meal].include?(first_column)

    raise ArgumentError, "first_column must be :resident or :meal, got #{first_column.inspect}"
  end
end
