# frozen_string_literal: true

# What a block runs after it first commits a write.
#
# A write action must answer from what it read inside its own
# transaction. Every query after the commit is a query that can fail, and
# a failure there reaches the rescue that answers "Nothing was saved. Try
# again." (ApiController#render_conflict, the settle rescues) about a
# change that is in the database. The one kind of step allowed to run SQL
# after the commit is a step that catches and reports its own errors, so
# no error from it can reach the answer. STEPS names each one.
#
#   result = after_commit_queries { post '/api/v1/...' }
#   result.committed  # => true when the block committed a write
#   result.queries    # => the SQL it ran after that commit, outside STEPS
#
# Run it with no test transaction (include_context 'with no test
# transaction'): inside the test's own transaction a write is never
# committed, and there is no COMMIT to find.
module AfterCommitQueries
  # [file, method]. A query whose call stack passes through one of these
  # is allowed after the commit.
  STEPS = [
    # Clears the caches and queues the pushes. Every clear and every push
    # reports its own failure, and a rescue around the rest reports the
    # reads that name the keys (LiveUpdate, "Nothing in the flush raises").
    ['app/services/live_update.rb', 'flush'],
    # A settlement's refresh of the running balances. It reports its own
    # failure, and the nightly job rebuilds the balances anyway
    # (SettleAndNotify.after_commit_step).
    ['app/services/settle_and_notify.rb', 'refresh_balances']
  ].freeze

  WRITE = /\A\s*(INSERT|UPDATE|DELETE)\b/i

  Statement = Data.define(:sql, :in_transaction, :in_step)
  Result = Data.define(:committed, :queries)

  def after_commit_queries(&)
    statements = record_statements(&)
    commit = first_commit_of_a_write(statements)
    return Result.new(committed: false, queries: []) if commit.nil?

    Result.new(committed: true, queries: statements.drop(commit + 1).reject(&:in_step).map(&:sql))
  end

  private

  def record_statements(&)
    statements = []
    record = lambda do |*, payload|
      next if payload[:name] == 'SCHEMA' || payload[:cached]

      statements << Statement.new(sql: payload[:sql].strip, in_transaction: !payload[:transaction].nil?,
                                  in_step: in_step?(caller_locations))
    end
    ActiveSupport::Notifications.subscribed(record, 'sql.active_record', &)
    statements
  end

  def in_step?(locations)
    locations.any? do |location|
      STEPS.any? { |file, method| location.path.to_s.end_with?(file) && location.base_label == method }
    end
  end

  # The index of the first statement that made a write permanent: the
  # COMMIT of a transaction that wrote, or a write that ran outside any
  # transaction (it commits on its own). Statements inside STEPS do not
  # count: LiveUpdate.flush queues its pushes in small transactions of
  # its own.
  def first_commit_of_a_write(statements)
    wrote = false
    statements.each_with_index do |statement, index|
      next if statement.in_step

      if statement.sql.match?(WRITE)
        return index unless statement.in_transaction

        wrote = true
      elsif statement.sql == 'COMMIT' && wrote
        return index
      elsif statement.sql == 'ROLLBACK'
        wrote = false
      end
    end
    nil
  end
end

RSpec.configure do |config|
  config.include AfterCommitQueries
end
