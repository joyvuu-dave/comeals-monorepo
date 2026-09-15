# frozen_string_literal: true

# The audits table (audited gem) stored auditable_id, associated_id and
# user_id as integer, from the gem's old migration template, while every
# id in this schema is bigint. The first id past 2,147,483,647 would have
# failed the audit write and, with it, the save that caused it (#83).
class ChangeAuditsIdsToBigint < ActiveRecord::Migration[8.1]
  ID_COLUMNS = %i[auditable_id associated_id user_id].freeze

  def up
    # safety_assured: strong_migrations refuses change_column because it
    # rewrites the table and blocks writes meanwhile. audits holds a few
    # thousand rows, so the rewrite takes well under a second.
    safety_assured do
      ID_COLUMNS.each { |column| change_column :audits, column, :bigint }
    end
  end

  def down
    safety_assured do
      ID_COLUMNS.each { |column| change_column :audits, column, :integer }
    end
  end
end
