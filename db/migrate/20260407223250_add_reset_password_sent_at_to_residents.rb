# frozen_string_literal: true

class AddResetPasswordSentAtToResidents < ActiveRecord::Migration[8.1]
  def change
    add_column :residents, :reset_password_sent_at, :datetime

    # Give any in-flight password resets a fresh 24-hour window from deploy time
    # rather than immediately invalidating them.
    reversible do |dir|
      dir.up do
        execute <<~SQL.squish
          UPDATE residents
          SET reset_password_sent_at = NOW()
          WHERE reset_password_token IS NOT NULL
        SQL
      end
    end
  end
end
