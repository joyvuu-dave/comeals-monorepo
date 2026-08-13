# frozen_string_literal: true

# The first accessibility fix (20260807130000) moved rotation red from
# #D9443F to #C9332E, which passes WCAG AA but looks visibly darker
# than the red residents were used to. #D53E3A also passes (4.6:1
# base, 6.2:1 dimmed, white text) and is nearly indistinguishable from
# the original. Rotation::COLORS now uses it; this moves the stored
# rows to match.
class MoveRotationRedBackTowardOriginal < ActiveRecord::Migration[8.1]
  def up
    # safety_assured: a two-value UPDATE on a table with a few dozen
    # rows; nothing strong_migrations can inspect inside execute.
    safety_assured do
      execute "UPDATE rotations SET color = '#D53E3A' WHERE color = '#C9332E'"
    end
  end

  def down
    safety_assured do
      execute "UPDATE rotations SET color = '#C9332E' WHERE color = '#D53E3A'"
    end
  end
end
