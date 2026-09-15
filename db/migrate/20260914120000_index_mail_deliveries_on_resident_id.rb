# frozen_string_literal: true

# Resident now has `has_many :mail_deliveries, dependent: :restrict_with_error`,
# so deleting a resident looks up mail_deliveries by resident_id. The only
# index that holds resident_id puts it last, after mailer, about_type and
# about_id, so that lookup could not use it.
class IndexMailDeliveriesOnResidentId < ActiveRecord::Migration[8.1]
  def change
    # safety_assured: strong_migrations wants indexes built concurrently so
    # they do not block writes. mail_deliveries has a few hundred rows, so
    # this build takes milliseconds — not worth losing the transaction.
    safety_assured do
      add_index :mail_deliveries, :resident_id
    end
  end
end
