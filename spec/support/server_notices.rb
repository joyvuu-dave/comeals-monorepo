# frozen_string_literal: true

# Fails an example when PostgreSQL sends a notice or a warning that the
# example did not expect.
#
# PostgreSQL answers some statements with a message that is not an error,
# such as "WARNING:  there is no transaction in progress" for a ROLLBACK
# with no transaction open. libpq prints these to stderr and goes on, so
# they used to scroll past in the RSpec output with no spec named. Each one
# means a session did something other than what its spec thinks it did.
#
# This file sets a notice processor on every connection the suite opens:
# the app's connections and every raw PG.connect session a race spec opens.
# A notice is recorded with no printing, and after each example any notice
# it did not expect fails it, with the text.
#
# An example that expects a notice says so in one of two ways:
#
#   - It wraps the statements that cause it in `capture_server_notices`,
#     which returns the notices sent while the block ran and checks none of
#     them. The example then checks the list itself, so the count is
#     pinned:
#
#       notices = capture_server_notices { expect { commit }.to raise_error(...) }
#       expect(notices).to eq([ServerNotices::REFUSED_COMMIT])
#
#   - Or it is tagged `server_notices: [pattern, ...]`, and each notice that
#     matches a pattern is allowed. For the storms, where the count depends
#     on timing. Say why next to the tag.
#
# The usual cause is a COMMIT that PostgreSQL refuses (a SERIALIZABLE
# conflict, or a deferred trigger that raises at COMMIT). The refusal ends
# the transaction, and Rails sends a ROLLBACK after it anyway
# (spec/db/commit_refused_spec.rb, #164), which PostgreSQL answers with
# REFUSED_COMMIT.
module ServerNotices
  # What PostgreSQL sends for the ROLLBACK that Rails sends after a refused
  # COMMIT.
  REFUSED_COMMIT = "WARNING:  there is no transaction in progress\n"

  # Raised by the check after an example.
  class Unexpected < StandardError; end

  # The notices recorded since the last check. Notices can come from other
  # threads (the storms), so every read and write takes the lock.
  # rubocop:disable ThreadSafety/MutableClassInstanceVariable -- one list for the whole run, guarded by the mutex
  @lock = Mutex.new
  @notices = []
  # rubocop:enable ThreadSafety/MutableClassInstanceVariable

  class << self
    def watch(connection)
      connection.set_notice_processor { |message| record(message) }
      connection
    end

    def record(message)
      @lock.synchronize { @notices << message }
    end

    # Every notice recorded so far, and empties the list.
    def take
      @lock.synchronize { @notices.slice!(0..) }
    end

    # The notices recorded while the block ran. They are taken off the
    # list, so the check after the example does not see them.
    def capture
      start = @lock.synchronize { @notices.size }
      yield
      @lock.synchronize { @notices.slice!(start..) || [] }
    end

    def check!(notices, allowed:, where:)
      unexpected = notices.reject { |message| allowed.any? { |pattern| pattern === message } } # rubocop:disable Style/CaseEquality
      return if unexpected.empty?

      raise Unexpected, "PostgreSQL sent #{unexpected.size} notice(s) #{where}:\n" \
                        "#{unexpected.map { |message| "  #{message.chomp}" }.join("\n")}\n" \
                        'If the example expects one, wrap the statements in capture_server_notices and ' \
                        'check what it returns, or tag the example server_notices: [pattern] with the ' \
                        'reason (spec/support/server_notices.rb).'
    end
  end

  # Every PG::Connection made from now on: PG.connect and the app's pool
  # both call PG::Connection.new.
  module WatchNewConnections
    def new(...)
      ServerNotices.watch(super)
    end
  end

  module Helpers
    def capture_server_notices(&)
      ServerNotices.capture(&)
    end

    # For a block that ends in one COMMIT PostgreSQL refuses, most often a
    # deferred trigger that raises at COMMIT: runs it, and checks that
    # PostgreSQL sent the one warning that follows a refused COMMIT and
    # nothing else.
    def expect_one_refused_commit(&)
      notices = ServerNotices.capture(&)
      expect(notices).to eq([REFUSED_COMMIT]), "expected one refused COMMIT, PostgreSQL sent #{notices.inspect}"
    end
  end
end

PG::Connection.singleton_class.prepend(ServerNotices::WatchNewConnections)

RSpec.configure do |config|
  config.include ServerNotices::Helpers

  # The connections made before this file loaded: the boot opens the app's
  # connection to check its isolation level
  # (config/initializers/verify_transaction_isolation.rb).
  config.before(:suite) do
    ActiveRecord::Base.connection_handler.connection_pool_list.flat_map(&:connections).each do |connection|
      ServerNotices.watch(connection.raw_connection)
    end
  end

  # Around, not before and after: the test transaction is rolled back in
  # rspec-rails' own around hook, after every after hook, and config-level
  # around hooks run outside it. So a notice from that rollback is counted
  # for its own example.
  config.around do |example|
    allowed = Array(example.metadata[:server_notices])
    # Anything recorded since the last check came from a before(:context)
    # hook or from between examples.
    ServerNotices.check!(ServerNotices.take, allowed: allowed, where: 'before this example started')
    example.run
    ServerNotices.check!(ServerNotices.take, allowed: allowed, where: 'that this example did not expect')
  end

  config.after(:suite) do
    ServerNotices.check!(ServerNotices.take, allowed: [], where: 'after the last example')
  end
end
