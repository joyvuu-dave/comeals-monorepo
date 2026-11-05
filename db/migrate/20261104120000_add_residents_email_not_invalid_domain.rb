# frozen_string_literal: true

# No resident may have an address ending in .invalid. The Common House
# screen signs in on the resident form with common-house@comeals.invalid
# (CommonHouseLogin::EMAIL), so a resident with that address would make
# a sign-in name two logins. Resident#email_not_reserved says this on
# the form; this CHECK holds it for writes that skip the model.
#
# No resident has such an address today (checked on the production copy
# of 2026-10-20), so adding the CHECK refuses no row. The previous
# release's code never writes one, so it runs beside this migration.
class AddResidentsEmailNotInvalidDomain < ActiveRecord::Migration[8.1]
  def change
    # safety_assured: strong_migrations wants the constraint added unvalidated
    # and validated in a second migration, to avoid a long lock on a big
    # table. residents has under a hundred rows; validation is instant.
    safety_assured do
      add_check_constraint :residents, "email IS NULL OR lower(email) NOT LIKE '%.invalid'",
                           name: 'residents_email_not_invalid_domain'
    end
  end
end
