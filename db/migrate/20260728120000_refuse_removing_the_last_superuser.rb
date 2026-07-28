# frozen_string_literal: true

# A community must always keep at least one superuser.
#
# ## What was wrong
#
# Nothing stopped the last superuser from deleting their own admin account.
# ActiveAdmin allowed destroy for superusers with no guard, so one click left
# the community with zero. Every remaining admin can then only read: nobody
# can settle a reconciliation, correct a bill, or promote anyone — and nobody
# can promote themselves out of it, because granting the superuser flag is
# itself a superuser action. The only way back is a console on the dyno.
#
# Verified before the fix with a request spec: superuser count went 1 -> 0.
#
# ## Why a trigger and not a constraint
#
# "At least one row in this table has superuser = true" is a statement about
# the table, not about a row, so no CHECK constraint or partial unique index
# can express it. A trigger is the only database-level way to say it.
#
# AdminUser#refuse_demoting_last_superuser and #refuse_destroying_last_superuser
# are the ordinary path and give a readable error in the admin UI. This is the
# backstop for everything that skips model callbacks — delete_all, update_all,
# update_column, a fixture load, psql.
#
# ## Why the lock
#
# The count must be taken under a lock, or two concurrent demotions each see
# the other's row as still-superuser and both commit, leaving zero. PERFORM
# ... FOR UPDATE locks the other superuser rows before the check and sets
# FOUND, so the second transaction waits and then sees committed state.
#
# If the two transactions are demoting each other, they deadlock and Postgres
# aborts one. That is a safe failure: the outcome is one demotion, refused or
# applied, never both.
class RefuseRemovingTheLastSuperuser < ActiveRecord::Migration[8.0]
  def up
    execute <<~SQL.squish
      CREATE OR REPLACE FUNCTION comeals_refuse_last_superuser_removal()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      BEGIN
        IF TG_OP = 'UPDATE' AND (NOT OLD.superuser OR NEW.superuser) THEN
          RETURN NEW;
        END IF;

        IF TG_OP = 'DELETE' AND NOT OLD.superuser THEN
          RETURN OLD;
        END IF;

        PERFORM 1 FROM admin_users
        WHERE superuser IS TRUE AND id <> OLD.id
        FOR UPDATE;

        IF NOT FOUND THEN
          RAISE EXCEPTION 'refusing to remove the last superuser (admin_users.id=%): the community would have no one able to settle reconciliations or grant admin access', OLD.id
            USING ERRCODE = 'raise_exception';
        END IF;

        IF TG_OP = 'DELETE' THEN
          RETURN OLD;
        END IF;

        RETURN NEW;
      END;
      $$;
    SQL

    execute <<~SQL.squish
      CREATE TRIGGER comeals_refuse_last_superuser_removal
      BEFORE UPDATE OR DELETE ON admin_users
      FOR EACH ROW
      EXECUTE FUNCTION comeals_refuse_last_superuser_removal();
    SQL
  end

  def down
    execute 'DROP TRIGGER IF EXISTS comeals_refuse_last_superuser_removal ON admin_users;'
    execute 'DROP FUNCTION IF EXISTS comeals_refuse_last_superuser_removal();'
  end
end
