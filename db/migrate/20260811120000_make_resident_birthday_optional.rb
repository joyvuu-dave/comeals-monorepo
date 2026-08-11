# frozen_string_literal: true

# A resident's birthday is now optional. NULL means "adult, no birthday
# given": the nightly multiplier task skips them and the calendar shows
# nothing. Before this, adults who did not want their birthday shown were
# given the placeholder date 1900-01-01, and the calendar showed them all
# as having Jan 1 birthdays.
#
# The CHECK keeps the placeholder from coming back through writes that
# skip the model (update_all, rake tasks, psql — see CLAUDE.md). It also
# rejects any date on or before 1900-01-01, which no living resident has.
#
# Rollback note: the previous release's code assumes birthday is never
# NULL. After this migration, a code-only rollback would make the nightly
# residents:set_multiplier task crash on the NULL rows (healthchecks
# would report it; the ledger is untouched). If you roll back the code,
# roll back this migration too — the down restores the placeholders.
class MakeResidentBirthdayOptional < ActiveRecord::Migration[8.1]
  SENTINEL = Date.new(1900, 1, 1)

  def up
    change_column_null :residents, :birthday, true
    change_column_default :residents, :birthday, from: SENTINEL, to: nil

    # Every placeholder becomes a real "no birthday" record. A child with
    # the placeholder would be a data error — the placeholder always meant
    # "treat as adult" — so surface it instead of hiding it.
    bad = select_value(<<~SQL.squish)
      SELECT count(*) FROM residents WHERE birthday = '1900-01-01' AND multiplier < 2
    SQL
    if bad.to_i.positive?
      raise "#{bad} resident(s) have the 1900-01-01 placeholder but a child " \
            'price category. Inspect and fix them by hand before migrating.'
    end

    # safety_assured: strong_migrations cannot inspect raw SQL. This is one
    # UPDATE on a table of under a hundred rows.
    safety_assured do
      execute("UPDATE residents SET birthday = NULL WHERE birthday = '1900-01-01'")
    end

    # safety_assured: strong_migrations wants the constraint added unvalidated
    # and validated in a second migration, to avoid a long lock on a big
    # table. residents has under a hundred rows; validation is instant.
    safety_assured do
      add_check_constraint :residents, "birthday IS NULL OR birthday > '1900-01-01'",
                           name: 'residents_birthday_not_sentinel'
    end
  end

  def down
    remove_check_constraint :residents, name: 'residents_birthday_not_sentinel'
    safety_assured do
      execute("UPDATE residents SET birthday = '1900-01-01' WHERE birthday IS NULL")
    end
    change_column_default :residents, :birthday, from: nil, to: SENTINEL
    change_column_null :residents, :birthday, false
  end
end
