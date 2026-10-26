# frozen_string_literal: true

require 'open3'

# A database of its own for one example, on the server the specs use: the
# local socket, or on CI the host, port and password in DATABASE_URL. The
# examples that run a Procfile command or boot the app in a child process
# point it here, so they never change the test database.
#
# Include it, call create_throwaway_database in a before hook and
# drop_throwaway_database in an after hook.
module ThrowawayDatabase
  def throwaway_database = "comeals_test#{ENV.fetch('TEST_DB_SUFFIX', '')}_throwaway"

  # The address of the database `name` on the server the specs use.
  def throwaway_url(name = throwaway_database)
    URI(ENV.fetch('DATABASE_URL', 'postgresql:///')).tap { it.path = "/#{name}" }.to_s
  end

  # Runs the SQL on the database `name`, on a connection of its own:
  # CREATE DATABASE cannot run inside the example's transaction.
  def on_database(name, *sql)
    pg = PG.connect(throwaway_url(name))
    sql.map { pg.exec(it) }.last
  ensure
    pg&.close
  end

  def throwaway_tables
    on_database(throwaway_database,
                "SELECT tablename FROM pg_tables WHERE schemaname = 'public' ORDER BY 1").column_values(0)
  end

  def create_throwaway_database
    drop_throwaway_database
    on_database('postgres', "CREATE DATABASE #{throwaway_database}")
  end

  # Not DROP DATABASE IF EXISTS: when there is none, PostgreSQL sends a
  # notice, and spec/support/server_notices.rb fails the example.
  def drop_throwaway_database
    exists = on_database('postgres', "SELECT 1 FROM pg_database WHERE datname = '#{throwaway_database}'")
             .ntuples.positive?
    on_database('postgres', "DROP DATABASE #{throwaway_database}") if exists
  end

  # Runs the command in the test environment, on the throwaway database.
  # DATABASE_URL names it: on CI DATABASE_URL is set and names the test
  # database, and its name wins over config/database.yml's.
  def run_on_throwaway_database(*command, env: {})
    env = { 'RAILS_ENV' => 'test', 'RUBYOPT' => nil, 'DATABASE_URL' => throwaway_url }.merge(env)
    Open3.capture2e(env, *command, chdir: Rails.root.to_s)
  end
end
