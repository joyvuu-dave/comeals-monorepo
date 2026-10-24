# frozen_string_literal: true

require 'rails_helper'

# db:create, db:drop and db:test:purge (which db:test:prepare runs) open a
# connection to the "postgres" database and send CREATE DATABASE or DROP
# DATABASE on it. Rails builds that connection from the same config as the
# app, so it got the 10 s statement_timeout from config/database.yml too.
#
# CREATE DATABASE forces a checkpoint, which writes every changed page on
# the whole server to disk. On the shared local server, while other
# worktrees run their tests, that took more than 10 s, and
# bin/agent-worktree failed with PG::QueryCanceled at db:test:purge.
#
# config/initializers/database_tasks_statement_timeout.rb turns the timeout
# off for that one connection. This spec opens a connection with the same
# config Rails uses there and asks PostgreSQL what it got.
RSpec.describe 'the connection the database tasks use for CREATE and DROP DATABASE' do
  let(:db_config) { ActiveRecord::Base.configurations.configs_for(env_name: 'test').first }
  let(:tasks) { ActiveRecord::Tasks::PostgreSQLDatabaseTasks.new(db_config) }
  # A private Rails method. If a Rails upgrade renames it, this line fails,
  # and the initializer must be changed to match.
  let(:config_hash) { tasks.send(:public_schema_config) }

  def show(setting)
    connection = ActiveRecord::ConnectionAdapters::PostgreSQLAdapter.new(config_hash)
    connection.select_value("SHOW #{setting}")
  ensure
    connection&.disconnect!
  end

  it 'connects to the postgres database, not the test database' do
    expect(config_hash[:database]).to eq('postgres')
  end

  it 'has no statement timeout' do
    expect(show('statement_timeout')).to eq('0')
  end

  it 'keeps the other session settings' do
    expect(show('default_transaction_isolation')).to eq('serializable')
    expect(show('lock_timeout')).to eq('5s')
  end

  it 'does not change the timeout for the app itself' do
    expect(db_config.configuration_hash.dig(:variables, 'statement_timeout')).to eq('10s')
    expect(ActiveRecord::Base.connection.select_value('SHOW statement_timeout')).to eq('10s')
  end
end
