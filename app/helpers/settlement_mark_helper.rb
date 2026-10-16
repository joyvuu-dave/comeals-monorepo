# typed: true
# frozen_string_literal: true

# The marks on a settlement page (ADR 0011 rule 8): what a line's mark
# says, and the small form that changes it.
module SettlementMarkHelper
  extend T::Sig
  extend T::Helpers

  requires_ancestor { ActionView::Base }
  requires_ancestor { ApplicationHelper }

  # A line's mark in words: the mark, its note, and who made it and when.
  # The read-only token sees when, not who (ApplicationHelper#names_admins?).
  # Empty for a line with no mark.
  def settlement_mark_words(mark)
    return '' if mark.nil?

    parts = [tag.strong(mark.words)]
    parts << tag.div(mark.note) if mark.note
    who = names_admins? ? "by #{mark.admin_user.email}, " : ''
    parts << tag.div("#{who}#{mark.created_at.strftime('%b %-d, %Y')}", class: 'mark-by')
    safe_join(parts, ' ')
  end

  # The form that changes a line's mark, posting to `action`. It sends the
  # newest mark it showed, so a change made by someone else after the page
  # was loaded is not overwritten (SettlementLineMarking). Let go is
  # offered only to an admin who may set it, and a line marked Let go can
  # be changed only by one. form_tag posts and adds the authenticity
  # token, and submit_tag adds data-disable-with, on their own.
  def settlement_mark_form(action, line, let_go_allowed:)
    current = line.current_mark
    if current&.status == SettlementLineMark::LET_GO && !let_go_allowed
      return 'Only a superuser can change a Let go mark.'
    end

    name = line.resident.name
    form_tag(action, class: 'settlement-mark') do
      safe_join([
                  hidden_field_tag(:line_id, line.id, id: nil),
                  hidden_field_tag(:seen, line.newest_mark&.id, id: nil),
                  select_tag(:status, options_for_select(mark_choices(let_go_allowed),
                                                         current&.status || SettlementLineMark::PAID),
                             id: nil, 'aria-label': "Mark for #{name}"),
                  text_field_tag(:note, current&.note, id: nil, placeholder: 'Note', 'aria-label': "Note for #{name}"),
                  submit_tag('Save', name: nil, 'aria-label': "Save the mark for #{name}")
                ], ' ')
    end
  end

  private

  def mark_choices(let_go_allowed)
    statuses = [SettlementLineMark::PAID]
    statuses << SettlementLineMark::LET_GO if let_go_allowed
    statuses << SettlementLineMark::NONE
    statuses.map { |status| [SettlementLineMark::WORDS.fetch(status), status] }
  end
end
