# frozen_string_literal: true

class RemoveNameFromGuests < ActiveRecord::Migration[8.1]
  def change
    remove_column :guests, :name, :string, default: '', null: false
  end
end
