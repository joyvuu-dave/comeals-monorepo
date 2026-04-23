# frozen_string_literal: true

# Supports the fresh-deploy bootstrap flow where an operator:
#   1. Creates an initial AdminUser via `rails c` on an empty database.
#   2. Logs into ActiveAdmin and creates the singleton Community via the UI.
#
# Before this change that flow was impossible:
#   - admin_users.community_id was NOT NULL, so step 1 failed.
#   - communities.timezone defaulted to "America/Los_Angeles", silently pinning
#     every new deployment to Pacific unless the operator remembered to change
#     it post-seed.
class SupportBootstrapViaActiveAdmin < ActiveRecord::Migration[8.1]
  def up
    # Allow orphan admin users during bootstrap. Once the singleton Community
    # is created, Community#after_create backfills community_id on every
    # pre-existing orphan, restoring the post-setup invariant that every admin
    # belongs to the one community.
    change_column_null :admin_users, :community_id, true

    # Force operators to make an explicit timezone choice when they create the
    # community. The ActiveAdmin form exposes Community::SUPPORTED_TIMEZONES
    # as a dropdown, and the model validates inclusion, so "explicit" doesn't
    # cost the operator anything — it just stops us silently defaulting to
    # Pacific for communities that aren't in Pacific.
    change_column_default :communities, :timezone, from: 'America/Los_Angeles', to: nil
  end

  def down
    change_column_default :communities, :timezone, from: nil, to: 'America/Los_Angeles'
    # Backfill any orphan admins before restoring NOT NULL. If there's no
    # Community yet (fresh DB being rolled back), we skip — the NOT NULL
    # constraint will simply re-apply with no rows to violate it.
    first_community_id = execute('SELECT id FROM communities ORDER BY id LIMIT 1').first&.fetch('id')
    if first_community_id
      execute("UPDATE admin_users SET community_id = #{first_community_id} WHERE community_id IS NULL")
    end
    change_column_null :admin_users, :community_id, false
  end
end
