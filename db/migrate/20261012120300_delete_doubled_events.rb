# frozen_string_literal: true

# Deletes events that were saved twice. One of the history fixes the owner
# decided on 2026-10-12, run during the deploy so no person has to do it by
# hand.
#
# Two or three events with the same title (ignoring capitals and spaces at
# the ends), the same start, the same end and the same all-day setting,
# almost always made one or two seconds apart, like a button clicked twice.
# The calendar showed each of them more than once. The production copy of
# 2026-10-11 has 8 such groups and 9 extra events, all in the past, the
# newest in December 2024. In two groups the descriptions differ a little
# ("Solar Panel contract" and "Solar Panel Contract ", and a blank one next
# to "common zoom").
#
# One event of each group stays: the one with the most description, not
# counting spaces at its ends, and the first one made when they tie. The
# rest are deleted. Events are not money and have no history rows, so the
# release log keeps everything each deleted event held, and that is how one
# could be put back by hand. A deleted row moves the row count the
# calendar's cache version reads (Community#calendar_cache_version), so the
# next calendar read builds the month again.
#
# Plain SQL, like migration 20261010130000, for the reasons given there.
# The events of the groups (each copy and the event it copies) are locked,
# in id order, and the groups are worked out again under the lock, so an
# edit made at the same moment is either seen or waits.
#
# down refuses: the release log holds what the deleted events held.
class DeleteDoubledEvents < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  ATTEMPTS = 5
  # Spaces at the ends of a title or a description do not count, the
  # no-break space (U+00A0) included: btrim leaves that one, and one
  # description in production ends with it. A plain SQL string, so the
  # regular expression reads \u00a0 itself.
  TRIMMED = "regexp_replace(%s, '^[[:space:]\\u00a0]+|[[:space:]\\u00a0]+$', '', 'g')"
  GROUP = "lower(#{format(TRIMMED, 'title')}), start_date, end_date, allday".freeze
  LONGEST_FIRST = "length(#{format(TRIMMED, "COALESCE(description, '')")}) DESC, id".freeze

  Copy = Struct.new(:id, :kept_id, :title, :description, :start_date, :end_date, :allday)

  def up
    with_retry { connection.transaction { delete_copies } }.each { |line| say line }
  end

  def down
    raise ActiveRecord::IrreversibleMigration,
          'Migration 20261012120300 deleted doubled events. Events have no history rows; the release log of ' \
          'the deploy that ran it lists everything each deleted event held.'
  end

  private

  # Returns the lines to print.
  def delete_copies
    first = copies
    return ['No event is doubled.'] if first.empty?

    lock(first.flat_map { |copy| [copy.id, copy.kept_id] }.uniq)
    found = copies
    return ['No event is doubled.'] if found.empty?

    connection.execute("DELETE FROM events WHERE id IN (#{found.map { |copy| Integer(copy.id) }.join(', ')})")
    found.map { |copy| described(copy) } + ["Deleted #{found.size} doubled event(s)."]
  end

  def lock(ids)
    return if ids.empty?

    connection.execute("SELECT id FROM events WHERE id IN (#{ids.map { |id| Integer(id) }.join(', ')}) " \
                       'ORDER BY id FOR UPDATE')
  end

  # Every event of a group but the one that stays, oldest start first.
  def copies
    connection.select_rows(<<~SQL.squish).map { |row| Copy.new(*row) }
      SELECT id, kept_id, title, description, start_date, end_date, allday
      FROM (SELECT events.*,
                   ROW_NUMBER() OVER kept AS place,
                   FIRST_VALUE(id) OVER kept AS kept_id
            FROM events
            WINDOW kept AS (PARTITION BY #{GROUP}
                            ORDER BY #{LONGEST_FIRST}
                            ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING)) ranked
      WHERE place > 1
      ORDER BY start_date, id
    SQL
  end

  # Everything the event held, so it could be put back by hand.
  def described(copy)
    "Deleted event #{copy.id}, a copy of event #{copy.kept_id}: #{copy.title.to_s.inspect}, " \
      "#{copy.start_date} to #{copy.end_date || 'no end'}, all day #{copy.allday}, " \
      "description #{copy.description.to_s.inspect}."
  end

  def with_retry
    attempt = 0
    begin
      attempt += 1
      yield
    rescue ActiveRecord::TransactionRollbackError, ActiveRecord::LockWaitTimeout
      raise if attempt >= ATTEMPTS || connection.transaction_open?

      say "PostgreSQL refused this for a conflict with another write. Trying again (#{attempt + 1} of #{ATTEMPTS}).",
          true
      sleep(0.1 * (2**attempt))
      retry
    end
  end
end
