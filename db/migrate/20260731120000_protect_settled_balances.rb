# frozen_string_literal: true

# Database guards for the settled amounts themselves.
#
# Until now the settled ledger's *source* rows were immutable — bills,
# attendance, guests, and the meal's settlement inputs, all refused by
# 20260707100000 and 20260727120000. The amounts those rows produce were not.
# reconciliation_balances was an ordinary table: an UPDATE from psql, a rake
# task, or update_all could rewrite what a resident owes, and the only trace
# would be the audit rows, which the same session can delete.
#
# That is the first question anyone asks about a settled number: can this be
# changed? It should not be answerable with "yes, quietly".
#
# Two triggers, doing two different jobs.
#
# 1. comeals_protect_settled_balance refuses UPDATE and DELETE. A settled
#    balance is written once, inside the settlement transaction, and never
#    again. Corrections settle as new entries in the next reconciliation
#    (CLAUDE.md money rule 7).
#
#    INSERT is allowed, because that is how settlement writes the rows in the
#    first place, and a row-level trigger cannot tell settlement's own inserts
#    from a later one. Trigger 2 is what covers that gap: a spurious insert
#    unbalances its reconciliation and is refused at commit.
#
# 2. reconciliation_balances_sum_zero asserts that every reconciliation's
#    stored balances sum to exactly zero. This is the accounting invariant the
#    whole settlement exists to produce — largest-remainder allocation
#    guarantees it in Ruby (Reconciliation#allocate_to_cents), and this makes
#    PostgreSQL guarantee it too, for writes that never went through Ruby.
#
#    It is a CONSTRAINT TRIGGER, DEFERRABLE INITIALLY DEFERRED, so it runs at
#    COMMIT rather than per row. That is what lets settlement insert thirty
#    rows one at a time: the ledger is unbalanced in the middle and balanced
#    at the end, which is the only moment that matters.
#
# The escape hatch (comeals.allow_settled_writes) applies to trigger 1 only,
# exactly as it does for the meal triggers. Trigger 2 ignores it on purpose:
# a repair may need to rewrite a settled amount, but no repair may leave the
# books not adding up. A multi-statement repair still works, because the
# check is deferred to commit and only judges the end state.
#
# See docs/runbooks/settled-data-repair.md.
class ProtectSettledBalances < ActiveRecord::Migration[8.1]
  def up
    # rubocop:disable Rails/SquishedSQLHeredocs -- PL/pgSQL function bodies need preserved formatting
    execute <<~SQL
      CREATE FUNCTION comeals_protect_settled_balance() RETURNS trigger AS $$
      BEGIN
        IF current_setting('comeals.allow_settled_writes', true) = 'on' THEN
          RETURN CASE TG_OP WHEN 'DELETE' THEN OLD ELSE NEW END;
        END IF;

        RAISE EXCEPTION '% on reconciliation_balances refused: reconciliation % is settled and its '
          'balances are what residents have already been billed. Corrections belong in the next '
          'reconciliation. For genuine data corruption see docs/runbooks/settled-data-repair.md.',
          TG_OP, OLD.reconciliation_id;
      END;
      $$ LANGUAGE plpgsql;
    SQL

    execute <<~SQL
      CREATE TRIGGER reconciliation_balances_protect_settled
      BEFORE UPDATE OR DELETE ON reconciliation_balances
      FOR EACH ROW EXECUTE FUNCTION comeals_protect_settled_balance();
    SQL

    # OLD and NEW are only assigned for the operations that have them —
    # reading OLD during an INSERT raises "record old is not assigned yet" —
    # so each is collected behind its own TG_OP check. An UPDATE that moves a
    # row between reconciliations must leave both of them balanced, which is
    # why both ids are gathered rather than just one.
    execute <<~SQL
      CREATE FUNCTION comeals_reconciliation_balances_sum_zero() RETURNS trigger AS $$
      DECLARE
        affected bigint[] := '{}';
        target_id bigint;
        total numeric;
      BEGIN
        IF TG_OP <> 'INSERT' THEN
          affected := affected || OLD.reconciliation_id;
        END IF;

        IF TG_OP <> 'DELETE' THEN
          affected := affected || NEW.reconciliation_id;
        END IF;

        FOREACH target_id IN ARRAY affected LOOP
          SELECT COALESCE(SUM(amount), 0) INTO total
          FROM reconciliation_balances WHERE reconciliation_id = target_id;

          IF total <> 0 THEN
            RAISE EXCEPTION 'reconciliation % refused: its stored balances sum to %, not zero. '
              'Every settlement must balance — what one resident is owed, others owe. '
              'See docs/runbooks/settled-data-repair.md.',
              target_id, total;
          END IF;
        END LOOP;

        RETURN NULL;
      END;
      $$ LANGUAGE plpgsql;
    SQL

    execute <<~SQL
      CREATE CONSTRAINT TRIGGER reconciliation_balances_sum_zero
      AFTER INSERT OR UPDATE OR DELETE ON reconciliation_balances
      DEFERRABLE INITIALLY DEFERRED
      FOR EACH ROW EXECUTE FUNCTION comeals_reconciliation_balances_sum_zero();
    SQL
    # rubocop:enable Rails/SquishedSQLHeredocs
  end

  def down
    execute 'DROP TRIGGER reconciliation_balances_sum_zero ON reconciliation_balances;'
    execute 'DROP FUNCTION comeals_reconciliation_balances_sum_zero();'
    execute 'DROP TRIGGER reconciliation_balances_protect_settled ON reconciliation_balances;'
    execute 'DROP FUNCTION comeals_protect_settled_balance();'
  end
end
