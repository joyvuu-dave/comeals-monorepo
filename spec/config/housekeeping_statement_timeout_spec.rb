# frozen_string_literal: true

require 'rails_helper'

# The 10 s statement_timeout in config/database.yml is for the code under
# test. The suite's own housekeeping is not that code: the TRUNCATE that
# cleans up after a group with no test transaction
# (spec/support/non_transactional_cleanup.rb), and the schema check and
# load before the first example (ActiveRecord::Migration.
# maintain_test_schema! in spec/rails_helper.rb). On the shared local
# server, with several test runs at once, both ran past 10 s and failed
# with PG::QueryCanceled, in specs that had nothing to do with them.
#
# These examples make a statement take longer than the session's timeout
# for certain: the session's limit is cut to 100 ms, and the statement
# waits a full second (for a lock another session holds, or in pg_sleep).
# Housekeeping must finish anyway, and leave the session's limit as it was.
RSpec.describe 'statement timeouts in the suite housekeeping' do
  include_context 'with no test transaction'

  let(:connection) { ActiveRecord::Base.connection }

  def open_session
    db = ActiveRecord::Base.connection_db_config.configuration_hash
    PG.connect(host: db[:host], port: db[:port], user: db[:username], password: db[:password], dbname: db[:database])
  end

  around do |example|
    connection.execute("SET statement_timeout = '100ms'")
    example.run
  ensure
    connection.execute("SET statement_timeout = '10s'")
  end

  it 'lets the cleanup TRUNCATE wait past the timeout, and keeps the timeout' do
    other = open_session
    other.exec('BEGIN')
    other.exec('LOCK TABLE units IN ACCESS SHARE MODE')
    release = Thread.new do
      sleep 1
      other.exec('COMMIT')
    end

    expect { NonTransactionalCleanup.call }.not_to raise_error
    expect(connection.select_value('SHOW statement_timeout')).to eq('100ms')
  ensure
    release&.join
    other&.close
  end

  describe 'TestHousekeeping.without_statement_timeout, around maintain_test_schema!' do
    it 'lets a statement run past the timeout' do
      expect { TestHousekeeping.without_statement_timeout { connection.execute('SELECT pg_sleep(1)') } }
        .not_to raise_error
    end

    it 'has no timeout on a connection opened inside it either, as after a schema load' do
      config = ActiveRecord::Base.connection_db_config.configuration_hash
      shown = TestHousekeeping.without_statement_timeout do
        opened = ActiveRecord::ConnectionAdapters::PostgreSQLAdapter.new(config)
        opened.select_value('SHOW statement_timeout')
      ensure
        opened&.disconnect!
      end

      expect(shown).to eq('0')
    end

    it 'puts the configured timeout back afterwards' do
      TestHousekeeping.without_statement_timeout { connection.execute('SELECT 1') }

      expect(connection.select_value('SHOW statement_timeout')).to eq('10s')
    end
  end
end
