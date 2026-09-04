# typed: false
# frozen_string_literal: true

# Financial records are append-only: once written they are never edited
# or deleted through the application — corrections settle as new entries
# in the next reconciliation (CLAUDE.md, money rule 7). Including this
# and declaring the two refusal messages installs the guards:
#
#   include AppendOnly
#   append_only update_message: '...', destroy_message: '...'
#
# The destroy guard is prepended: dependent callbacks declared before it
# register their cascades first, and without prepend a refused destroy
# would still run those cascades — inside an enclosing transaction the
# swallowed inner rollback leaves partial deletes (issue #26).
#
# These guards are the readable half. The database triggers (see the
# migrations named in each model) are the backstop for writes that skip
# callbacks entirely.
module AppendOnly
  extend ActiveSupport::Concern

  class_methods do
    def append_only(update_message:, destroy_message:)
      before_update -> { append_only_refuse(update_message) }
      before_destroy -> { append_only_refuse(destroy_message) }, prepend: true
    end
  end

  private

  def append_only_refuse(message)
    errors.add(:base, message)
    throw(:abort)
  end
end
