# frozen_string_literal: true

# One row per email the app sent to a resident about a record: which
# mailer, about what, to whom, when. Append-only, like job_runs.
#
# This is what lets a mail run stop and start again without sending anyone
# a second copy: a run mails only the people who have no row yet, and
# writes a row after each send. The cook mail after a settlement
# (NotifyCooksJob) and the two rotation broadcasts use it (#71, #74).
class CreateMailDeliveries < ActiveRecord::Migration[8.1]
  def up
    create_table :mail_deliveries do |t|
      t.string :mailer, null: false
      t.string :about_type, null: false
      t.bigint :about_id, null: false
      t.references :resident, null: false, foreign_key: true, index: false
      t.datetime :sent_at, null: false
      t.timestamps
    end
    # One email per mailer, per record, per person. The unique index is the
    # rule; the model's uniqueness validation only gives a readable error.
    add_index :mail_deliveries, %i[mailer about_type about_id resident_id], unique: true,
                                                                            name: 'index_mail_deliveries_one_per_person'

    safety_assured do
      execute <<~SQL.squish
        CREATE FUNCTION comeals_protect_mail_delivery() RETURNS trigger AS $$
        BEGIN
          RAISE EXCEPTION '% on mail_deliveries refused: a sent email is a record of what happened, so it is never edited or deleted',
            TG_OP;
        END;
        $$ LANGUAGE plpgsql;

        CREATE TRIGGER mail_deliveries_protect
        BEFORE UPDATE OR DELETE ON mail_deliveries
        FOR EACH ROW EXECUTE FUNCTION comeals_protect_mail_delivery();
      SQL
    end
  end

  def down
    execute 'DROP TRIGGER mail_deliveries_protect ON mail_deliveries;'
    execute 'DROP FUNCTION comeals_protect_mail_delivery();'
    drop_table :mail_deliveries
  end
end
