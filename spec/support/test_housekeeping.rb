# frozen_string_literal: true

# No statement timeout for the suite's own housekeeping.
#
# The 10 s statement_timeout in config/database.yml is for the code under
# test: a slow query there is a bug, and the error should say so. The
# suite's housekeeping is not that code. On the shared local server, with
# several test runs at once, a schema check before the first example
# (maintain_test_schema!, which reads the catalog and may drop, create and
# load the database) ran past 10 s and failed a child process's spec that
# had nothing to do with it. spec/config/housekeeping_statement_timeout_spec.rb
# shows the limit is off inside the block and back after it.
#
# The cleanup TRUNCATE turns the limit off with SET LOCAL in its own
# transaction instead (spec/support/non_transactional_cleanup.rb).
# CREATE and DROP DATABASE have their own fix
# (config/initializers/database_tasks_statement_timeout.rb).
module TestHousekeeping
  # Every connection opened while a block runs, so the block can put the
  # limit back on each. A schema load drops the database, so the
  # connection after it is a new one.
  # The lock because the prepended configure_connection can run on any
  # thread that opens a connection.
  @lock = Mutex.new
  @opened = nil

  class << self
    # Runs the block with no statement timeout on the app's connection and
    # on any connection opened inside it, then sets the configured timeout
    # again on each of them.
    def without_statement_timeout
      @lock.synchronize { @opened = [] }
      ActiveRecord::Base.connection.execute('SET statement_timeout = 0')
      yield
    ensure
      configured = ActiveRecord::Base.connection_db_config.configuration_hash
                                     .fetch(:variables, {}).stringify_keys.fetch('statement_timeout')
      opened = @lock.synchronize { @opened.tap { @opened = nil } }
      [ActiveRecord::Base.connection, *opened].uniq.each do |connection|
        next unless connection.active?

        connection.execute("SET statement_timeout = #{connection.quote(configured)}")
      end
    end

    def opened(connection)
      watching = @lock.synchronize { @opened&.push(connection) }
      connection.execute('SET statement_timeout = 0') if watching
    end
  end

  # Runs after Rails sets the session variables on a new connection.
  module NewConnections
    private

    def configure_connection
      super
      TestHousekeeping.opened(self)
    end
  end
end

ActiveSupport.on_load(:active_record_postgresqladapter) { prepend TestHousekeeping::NewConnections }
