# typed: strict
# frozen_string_literal: true

# Marks a settlement line Paid or Let go, or takes its mark off (ADR 0011
# rule 8). Each change is a new SettlementLineMark, so the old mark stays
# in the line's history and the newest counts.
#
# The page sends the newest mark it showed (`seen`, nil for a line it
# showed with none). The line's row is locked first, so two changes to one
# line run one after the other, and a change made on a page that did not
# see the newest mark is refused with nothing saved: two admins at the
# same moment cannot overwrite each other without seeing it. The same rule
# as a cook's cost (ADR 0009).
#
# Who may make a change is the caller's to check (SuperuserAdapter, the
# :let_go action), from the status and the seen mark.
class SettlementLineMarking
  extend T::Sig

  # The line's mark changed after the page showed it.
  class Changed < StandardError; end

  # The status and the note are the line's already.
  class NothingChanged < StandardError; end

  sig do
    params(line: ReconciliationBalance, status: String, note: T.nilable(String), by: AdminUser,
           seen: T.nilable(Integer)).returns(SettlementLineMark)
  end
  def self.mark!(line, status:, note:, by:, seen:)
    RetryOnConflict.call do
      ReconciliationBalance.transaction do
        line.lock!
        newest = SettlementLineMark.where(reconciliation_balance_id: line.id).last
        if newest&.id != seen
          raise Changed, "Someone changed this line's mark after the page was loaded, so nothing was saved. " \
                         'This is the page as it is now.'
        end

        mark = SettlementLineMark.new(reconciliation_balance: line, status: status, note: note, admin_user: by)
        refuse_no_change!(newest, mark)
        mark.save!
        mark
      end
    end
  end

  # The newest mark already says this; with none, "No mark" says nothing new.
  sig { params(newest: T.nilable(SettlementLineMark), mark: SettlementLineMark).void }
  def self.refuse_no_change!(newest, mark)
    same = if newest
             newest.status == mark.status && newest.note == mark.note
           else
             mark.status == SettlementLineMark::NONE
           end
    return unless same

    raise NothingChanged, 'This line has no mark already.' if mark.status == SettlementLineMark::NONE

    raise NothingChanged, "This line is marked #{mark.words} already, with the same note."
  end
  private_class_method :refuse_no_change!
end
