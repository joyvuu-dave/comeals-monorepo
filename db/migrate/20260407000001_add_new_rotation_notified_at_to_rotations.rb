# frozen_string_literal: true

class AddNewRotationNotifiedAtToRotations < ActiveRecord::Migration[8.1]
  def change
    add_column :rotations, :new_rotation_notified_at, :datetime, null: true
  end
end
