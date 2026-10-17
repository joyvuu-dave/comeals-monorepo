# frozen_string_literal: true

module Storm
  # Sends a request again while it is answered 409, for up to
  # GIVE_UP_AFTER seconds.
  #
  # With nothing else in the test database, PostgreSQL still refuses every
  # write while a SERIALIZABLE transaction that has written something
  # stays open in another database on the same server (#218). That
  # transaction keeps Postgres from freeing its records of the
  # transactions that committed after it started. When the space for
  # them is full, Postgres keeps only a summary of the oldest ones, and
  # then it can no longer tell that the writers of old row versions
  # finished before a read began. It assumes a conflict, and the reason
  # code is "Canceled on identification as a pivot, during write". Every
  # try fails the same way until the other transaction ends. On a laptop
  # where other worktrees run their tests against the same server, such
  # a transaction lasts a few seconds. A limit of a few tries in a row
  # used less than a second.
  module Refusals
    PAUSE = 0.1
    GIVE_UP_AFTER = 30.0

    # The block sends the request once and returns [status, body].
    # Returns the first answer that is not a 409. on_conflict is called
    # for each 409. The pause between tries is PAUSE to twice PAUSE, so
    # threads that conflicted with each other do not try again together.
    def self.retry(label, give_up_after: GIVE_UP_AFTER, on_conflict: nil)
      started = now
      loop do
        answer = yield
        return answer unless answer.first == 409

        on_conflict&.call
        break if now - started >= give_up_after

        sleep(PAUSE * (1 + Kernel.rand))
      end
      raise "#{label} answered 409 for #{give_up_after} seconds in a row. " \
            "Open transactions on this server that have written something: #{open_writers}"
    end

    # The sessions on this Postgres server, in any database, inside a
    # transaction that has written something and has been open for more
    # than a second. One of them is the likely cause of a run of 409s.
    def self.open_writers
      rows = ActiveRecord::Base.connection.select_rows(<<~SQL.squish)
        SELECT datname, pid, round(extract(epoch FROM now() - xact_start)::numeric, 1)
        FROM pg_stat_activity
        WHERE backend_xid IS NOT NULL AND pid <> pg_backend_pid() AND xact_start < now() - interval '1 second'
        ORDER BY xact_start
      SQL
      return 'none' if rows.empty?

      rows.map { |database, pid, open_for| "#{database} (pid #{pid}, open #{open_for}s)" }.join(', ')
    end

    def self.now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
