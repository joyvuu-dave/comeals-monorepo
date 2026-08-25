# frozen_string_literal: true

# Not a schema change. Postgres prints a CHECK from its parse tree, and the
# tree it built from add_check_constraint "outcome IN ('ok', 'failed')"
# prints as `ANY ((ARRAY[...])::text[])`, while the tree it builds from that
# printed text prints as `ANY (ARRAY[(...)::text, ...])`. So a database that
# ran the migrations and one that loaded db/structure.sql disagreed on one
# line, and every merge that migrated the development database rewrote
# structure.sql with it. Re-stating the constraint in the printed form makes
# both paths print the same text, so the file stops flipping.
class RestateJobRunsOutcomeCheck < ActiveRecord::Migration[8.1]
  def up
    safety_assured do
      remove_check_constraint :job_runs, name: 'job_runs_outcome_known'
      add_check_constraint :job_runs,
                           "((outcome)::text = ANY (ARRAY[('ok'::character varying)::text, " \
                           "('failed'::character varying)::text]))",
                           name: 'job_runs_outcome_known'
    end
  end

  def down
    # Same rule, either spelling; nothing to undo.
  end
end
