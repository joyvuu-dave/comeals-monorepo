# frozen_string_literal: true

# Remove the community slug and the friendly_id_slugs table.
#
# The slug came from the app's multi-tenant era, when each community was
# found by its slug. The app is single-tenant now: Community is a singleton,
# nothing looks a community up by slug, no route or controller reads it, and
# the frontend never read the slug key the login response sent. The
# friendly_id_slugs history table was dead from the start — the model used
# `use: :slugged`, not `:history`, so nothing ever wrote to it.
#
# Production no longer has the table: the developer dropped it by hand
# before this migration ever ran there. So the 2026-08-17 staging
# rehearsal failed here — drop_table raised "table does not exist"
# against a fresh copy of production. Hence if_exists below. (An
# earlier version of this comment claimed production never had the
# table; that was wrong.)
class RemoveSlugFromCommunities < ActiveRecord::Migration[8.1]
  def up
    # safety_assured: the release before this one still reads slug (the
    # login response and the admin pages), so a code-only rollback past
    # this migration would break login. The hand-checked story: run
    # `rails db:rollback` (the down below restores the column and its
    # data) before or with the code rollback. Accepted because slug is
    # not read anywhere on the money path and the window is one release.
    safety_assured do
      remove_column :communities, :slug
      drop_table :friendly_id_slugs, if_exists: true
    end
  end

  def down
    add_column :communities, :slug, :string
    # The old slug was generated from the name; parameterize is the same
    # transform friendly_id applied.
    execute(<<~SQL.squish)
      UPDATE communities
      SET slug = regexp_replace(regexp_replace(lower(name), '[^a-z0-9]+', '-', 'g'), '(^-|-$)', '', 'g')
    SQL
    change_column_null :communities, :slug, false
    add_index :communities, :slug, unique: true

    create_table :friendly_id_slugs do |t|
      t.string :slug, null: false
      t.integer :sluggable_id, null: false
      t.string :sluggable_type, limit: 50
      t.string :scope
      t.datetime :created_at
    end
    add_index :friendly_id_slugs, %i[slug sluggable_type]
    add_index :friendly_id_slugs, %i[slug sluggable_type scope], unique: true
    add_index :friendly_id_slugs, :sluggable_id
    add_index :friendly_id_slugs, :sluggable_type
  end
end
