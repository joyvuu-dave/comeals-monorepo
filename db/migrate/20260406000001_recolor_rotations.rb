# frozen_string_literal: true

class RecolorRotations < ActiveRecord::Migration[7.0]
  def up
    Community.find_each do |community|
      Rotation.recolor_community(community.id)
    end
  end

  def down
    # Color assignments before this migration were non-deterministic
    # due to a missing ORDER BY clause. Cannot be meaningfully reversed.
  end
end
