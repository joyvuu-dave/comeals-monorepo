# frozen_string_literal: true

# A mail_deliveries row with no resident: a mail sent to a fixed address
# that is not a person's. The first one is the email to the common house
# after a settlement (CommonHouseMailJob, ADR 0011 rule 9).
#
# The old unique index allows one row per mailer, record and person. It
# cannot hold a mail with no person to one row, because Postgres counts
# two NULL resident_ids as different. A partial unique index does that
# for the rows with no resident.
#
# The table is created by the same deploy (20260825100000), so it is
# empty when this runs, and the index locks no row anyone is using.
class AllowMailDeliveriesWithoutAResident < ActiveRecord::Migration[8.1]
  def change
    change_column_null :mail_deliveries, :resident_id, true
    safety_assured do
      add_index :mail_deliveries, %i[mailer about_type about_id], unique: true, where: 'resident_id IS NULL',
                                                                  name: 'index_mail_deliveries_one_to_no_person'
    end
  end
end
