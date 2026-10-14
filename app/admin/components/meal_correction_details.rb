# typed: false
# frozen_string_literal: true

# One correction to a settled dinner (ADR 0011 rule 6): when and by whom,
# the reason, what changed, and each person's change. Shared by the
# dinner's page, the settlement that carries it, and the settlement
# preview, so all three say the same thing.
#
# The caller loads the correction with its admin user and its lines'
# residents, and passes `residents`, every resident the edits name, by
# id, loaded once for the page.
class MealCorrectionDetails < Arbre::Component
  builder_method :meal_correction_details

  # Arbre passes builder options as a plain hash, not Ruby keywords.
  def build(correction, options = {})
    residents = options.fetch(:residents)
    para "Made #{correction.created_at.strftime('%b %-d, %Y')} by #{correction.admin_user.email}. " \
         "Reason: #{correction.reason}"
    ul do
      correction.edits.each { |edit| li CorrectionWords.edit(edit, residents) }
    end
    if correction.lines.empty?
      para 'Nobody owes or is owed a different amount.'
    else
      table_for(correction.lines.sort_by { |line| line.resident.name }) do
        column('Resident') { |line| link_to line.resident.name, admin_resident_path(line.resident) }
        column('Change') { |line| correction_amount_tag(line.amount) }
      end
    end
  end
end
