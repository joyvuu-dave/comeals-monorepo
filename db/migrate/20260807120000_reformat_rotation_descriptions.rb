# frozen_string_literal: true

# Rotation descriptions are stored strings ("2026-07-16 to 2026-08-13")
# rebuilt from meal dates on every save. The format changed to month
# names ("Jul 16 – Aug 13, 2026"); this rewrites the stored rows.
class ReformatRotationDescriptions < ActiveRecord::Migration[8.1]
  def up
    Rotation.reset_column_information
    Rotation.find_each(&:set_description)
  end

  def down
    # Rebuild the old ISO format straight from meal dates — the
    # description is derived data, so nothing is lost. A rotation with
    # no meals gets " to ", exactly what the old code produced.
    execute <<~SQL.squish
      UPDATE rotations SET description =
        COALESCE((SELECT min(date)::text FROM meals WHERE meals.rotation_id = rotations.id), '')
        || ' to ' ||
        COALESCE((SELECT max(date)::text FROM meals WHERE meals.rotation_id = rotations.id), '')
    SQL
  end
end
