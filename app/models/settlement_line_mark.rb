# typed: strict
# frozen_string_literal: true

# A mark on a settlement line (ADR 0011 rule 8): the person paid, or the
# amount was let go, with an optional note ("paid $20 of $40"). A mark
# never changes what anyone owes; it records what happened after the
# settlement. Each change is a new row, so the rows of a line are its
# history and the newest one counts (ReconciliationBalance#current_mark).
# "none" takes a mark off a line marked by mistake.
#
# Written only by SettlementLineMarking. Any admin may mark a line Paid;
# setting or changing a Let go mark is a decision about money, so it needs
# a superuser (SuperuserAdapter, the :let_go action). Its CHECKs
# (settlement_line_marks_status_known, settlement_line_marks_note_not_blank)
# and its trigger (comeals_protect_settlement_line_mark) are in
# db/structure.sql.
# == Schema Information
#
# Table name: settlement_line_marks
#
#  id                        :bigint           not null, primary key
#  note                      :text
#  status                    :string           not null
#  created_at                :datetime         not null
#  updated_at                :datetime         not null
#  admin_user_id             :bigint           not null
#  reconciliation_balance_id :bigint           not null
#
# Indexes
#
#  index_settlement_line_marks_on_admin_user_id              (admin_user_id)
#  index_settlement_line_marks_on_reconciliation_balance_id  (reconciliation_balance_id)
#
# Foreign Keys
#
#  fk_rails_...  (admin_user_id => admin_users.id)
#  fk_rails_...  (reconciliation_balance_id => reconciliation_balances.id)
#
class SettlementLineMark < ApplicationRecord
  extend T::Sig

  PAID = 'paid'
  LET_GO = 'let_go'
  NONE = 'none'
  STATUSES = T.let([PAID, LET_GO, NONE].freeze, T::Array[String])
  # The words a page shows for each status.
  WORDS = T.let({ PAID => 'Paid', LET_GO => 'Let go', NONE => 'No mark' }.freeze, T::Hash[String, String])

  belongs_to :reconciliation_balance, inverse_of: :marks
  belongs_to :admin_user

  validates :status, inclusion: { in: STATUSES, message: 'must be Paid, Let go or No mark' }
  # A blank note is no note: the database refuses one made of spaces.
  normalizes :note, with: ->(note) { note.strip.presence }

  # Append-only. The trigger comeals_protect_settlement_line_mark refuses an update or a
  # delete that skips this.
  include AppendOnly

  append_only update_message: 'A mark is a record of what happened after a settlement and cannot be modified. ' \
                              'Mark the line again; the newest mark counts.',
              destroy_message: 'A mark is a record of what happened after a settlement and cannot be destroyed.'

  sig { returns(String) }
  def words
    WORDS.fetch(T.must(status))
  end
end
