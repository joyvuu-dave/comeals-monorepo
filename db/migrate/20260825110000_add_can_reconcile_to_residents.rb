# frozen_string_literal: true

# Who may settle the period through the API (#72). Settling claims meals,
# writes the ledger, and mails every cook, with no undo, and a resident
# token never expires — so it is not for every resident. The flag is set
# in admin by a superuser, the same tier that may write a Reconciliation
# there. Nobody has it until a superuser grants it.
class AddCanReconcileToResidents < ActiveRecord::Migration[8.1]
  def change
    add_column :residents, :can_reconcile, :boolean, null: false, default: false
  end
end
