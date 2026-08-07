# frozen_string_literal: true

# The rotation red #D9443F sat on the boundary where neither black nor
# white text passes WCAG AA once the calendar desaturates past events.
# Rotation::COLORS now uses #C9332E (see the comment there); this moves
# the stored rows to match.
class DarkenRotationRed < ActiveRecord::Migration[8.1]
  def up
    execute "UPDATE rotations SET color = '#C9332E' WHERE color = '#D9443F'"
  end

  def down
    execute "UPDATE rotations SET color = '#D9443F' WHERE color = '#C9332E'"
  end
end
