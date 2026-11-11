# frozen_string_literal: true

# The community's zone must be one of Community::SUPPORTED_TIMEZONES. The
# model's validation says so on the form; this CHECK holds it for a write
# that skips the model. A zone name Rails does not know makes
# Community#today raise, and with it every page that shows a date.
#
# The list is written out here, not read from the model, because a
# migration must keep doing the same thing when the model changes later.
# spec/db/communities_timezone_check_spec.rb fails when the two lists
# differ, so adding a zone to the model needs a migration that changes
# this CHECK.
#
# The production copy of 2026-11-11 stores America/Los_Angeles, which is
# in the list, so adding the CHECK refuses no row. The previous release's
# code writes only zones from the same list, so it runs beside this
# migration.
class AddCommunitiesTimezoneSupported < ActiveRecord::Migration[8.1]
  ZONES = %w[
    Pacific/Honolulu America/Juneau America/Los_Angeles America/Denver
    America/Phoenix America/Chicago America/New_York America/Halifax
    Europe/London Europe/Paris Europe/Berlin Europe/Helsinki
    Asia/Tokyo Australia/Sydney Pacific/Auckland
  ].freeze

  # timezone::text, not timezone: on a varchar column, PostgreSQL prints a
  # plain IN one way after this migration and another way after
  # db/structure.sql is loaded again, and spec/db/structure_sql_spec.rb
  # needs the two to match.
  def change
    # safety_assured: strong_migrations wants the constraint added unvalidated
    # and validated in a second migration, to avoid a long lock on a big
    # table. communities has one row; validation is instant.
    safety_assured do
      add_check_constraint :communities, "timezone::text IN (#{ZONES.map { |zone| "'#{zone}'" }.join(', ')})",
                           name: 'communities_timezone_supported'
    end
  end
end
