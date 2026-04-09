# frozen_string_literal: true

class RecolorRotations < ActiveRecord::Migration[7.0]
  def up
    Rotation.recolor_community
  end

  def down
    # Color assignments before this migration were non-deterministic
    # due to a missing ORDER BY clause. Cannot be meaningfully reversed.
  end
end
