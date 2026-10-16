# frozen_string_literal: true

require 'rails_helper'

RSpec.describe SnapshotRead do
  # SHOW, not SELECT. A SELECT takes a snapshot, and a DEFERRABLE
  # transaction waits for its first snapshot until every SERIALIZABLE
  # writer on the server has finished, in every database, so a write
  # left open in another worktree's database held the example that turns
  # DEFERRABLE on past the statement timeout. SHOW takes no snapshot, so
  # it never waits.
  def transaction_modes
    connection = ActiveRecord::Base.connection
    %w[isolation read_only deferrable].index_with { |mode| connection.select_value("SHOW transaction_#{mode}") }
  end

  def session_default_isolation
    ActiveRecord::Base.connection.select_value('SHOW default_transaction_isolation')
  end

  # The real path. Transactional fixtures would leave a transaction already
  # open, which is the case SnapshotRead deliberately skips, so this group
  # runs without them.
  describe 'with no transaction already open' do
    include_context 'with no test transaction'

    # The test environment turns the setting off (config/environments/test.rb),
    # so the example that checks the production mode turns it back on.
    def with_deferrable(value)
      was = Rails.configuration.x.snapshot_reads_deferrable
      Rails.configuration.x.snapshot_reads_deferrable = value
      yield
    ensure
      Rails.configuration.x.snapshot_reads_deferrable = was
    end

    # Another session's SERIALIZABLE transaction. A DEFERRABLE transaction
    # waits for every one of these on the server, in every database, before
    # it takes its first snapshot. So this one stands in for a write that
    # another worktree, a mutant worker, or another customer on the shared
    # production server left open. It is a raw PG connection because the
    # test pool has only one. Closing the session rolls the transaction
    # back. It wrote nothing.
    def serializable_transaction_elsewhere
      db = ActiveRecord::Base.connection_db_config.configuration_hash
      other = PG.connect(host: db[:host], port: db[:port], user: db[:username],
                         password: db[:password], dbname: db[:database])
      other.exec('BEGIN ISOLATION LEVEL SERIALIZABLE')
      # Its first snapshot is what puts it on the server's list.
      other.exec('SELECT 1')
      other
    end

    # The transaction above, open for the whole block.
    def with_serializable_transaction_open_elsewhere
      other = serializable_transaction_elsewhere
      yield
    ensure
      other&.close
    end

    # The transaction above, ended from a thread after `seconds`, so a
    # DEFERRABLE read started in the block waits about that long.
    def with_serializable_transaction_ending_after(seconds)
      other = serializable_transaction_elsewhere
      ender = Thread.new do
        sleep seconds
        other.close
      end
      yield
    ensure
      ender&.join
    end

    # This session's statement timeout, set for the block and put back.
    def with_statement_timeout(value)
      connection = ActiveRecord::Base.connection
      was = connection.select_value('SHOW statement_timeout')
      connection.execute("SET statement_timeout = #{connection.quote(value)}")
      yield
    ensure
      connection.execute("SET statement_timeout = #{connection.quote(was)}")
    end

    # This session's default isolation, set for the block and put back.
    def with_session_isolation(value)
      connection = ActiveRecord::Base.connection
      was = session_default_isolation
      connection.execute("SET default_transaction_isolation = #{connection.quote(value)}")
      yield
    ensure
      connection.execute("SET default_transaction_isolation = #{connection.quote(was)}")
    end

    it 'opens the transaction SERIALIZABLE READ ONLY DEFERRABLE when the setting is on, as in production' do
      modes = with_serializable_transaction_open_elsewhere do
        with_deferrable(true) { described_class.call { transaction_modes } }
      end

      expect(modes['isolation']).to eq('serializable')
      expect(modes['read_only']).to eq('on')
      # DEFERRABLE is what makes this transaction unable to fail with a
      # serialization error, so it needs no retry. It only takes effect
      # together with the other two.
      expect(modes['deferrable']).to eq('on')
    end

    # config/environments/test.rb says why the setting is off in tests.
    # Production and development keep it on:
    # spec/config/snapshot_reads_deferrable_spec.rb.
    it 'leaves DEFERRABLE out in the test environment, and keeps SERIALIZABLE READ ONLY' do
      modes = described_class.call { transaction_modes }

      expect(modes['isolation']).to eq('serializable')
      expect(modes['read_only']).to eq('on')
      expect(modes['deferrable']).to eq('off')
    end

    # config/database.yml makes every session of this app SERIALIZABLE
    # (ADR 0005), so the examples above would pass without the isolation
    # SnapshotRead asks for. It asks anyway, so a session that starts
    # lower, as psql does, still gets one snapshot for the whole read.
    it 'opens the transaction SERIALIZABLE when the session starts at a lower level' do
      modes = with_session_isolation('read committed') { described_class.call { transaction_modes } }

      expect(modes['isolation']).to eq('serializable')
    end

    it 'refuses a write inside the block' do
      expect do
        # Matches no row on purpose. PostgreSQL refuses the statement for
        # being a write at all, before it looks at what it would change.
        described_class.call { Unit.where(id: -1).update_all(name: 'should not be written') }
      end.to raise_error(ActiveRecord::StatementInvalid, /read-only transaction/)
    end

    it 'returns the block value' do
      expect(described_class.call { 42 }).to eq(42)
    end

    it 'closes the transaction' do
      described_class.call { transaction_modes }

      expect(ActiveRecord::Base.connection.transaction_open?).to be(false)
    end

    # In these examples 0.5 seconds stands in for the 10 s statement
    # timeout, and a write that ends after 1.5 seconds for a stranger's
    # slower write on the shared production server.
    describe 'wait_limit' do
      it 'is needed: without it, the wait for the snapshot stops at the statement timeout' do
        expect do
          with_statement_timeout('500ms') do
            with_serializable_transaction_ending_after(1.5) do
              with_deferrable(true) { described_class.call { Unit.count } }
            end
          end
        end.to raise_error(ActiveRecord::QueryCanceled)
      end

      it 'lets the wait for the snapshot run past the statement timeout' do
        # A minute, not 1.5 seconds: a DEFERRABLE read also waits for any
        # other worktree's tests, which this example cannot stop.
        count = with_statement_timeout('500ms') do
          with_serializable_transaction_ending_after(1.5) do
            with_deferrable(true) { described_class.call(wait_limit: 1.minute) { Unit.count } }
          end
        end

        expect(count).to eq(0)
      end

      it 'keeps the statement timeout for the reads after the wait' do
        expect do
          with_statement_timeout('500ms') do
            described_class.call(wait_limit: 1.minute) { ActiveRecord::Base.connection.execute('SELECT pg_sleep(1)') }
          end
        end.to raise_error(ActiveRecord::QueryCanceled)
      end
    end
  end

  # The two nightly jobs pass it. Longer than the 10 s statement timeout,
  # or there would be no point, and shorter than the hour RecurringJob lets
  # one run hold its place, so a run that gives up still frees it.
  describe 'NIGHTLY_WAIT' do
    it 'is longer than the statement timeout and shorter than a recurring run may take' do
      timeout = ActiveRecord::Base.connection_db_config.configuration_hash.fetch(:variables).fetch('statement_timeout')

      expect(described_class::NIGHTLY_WAIT).to be > Integer(timeout.delete_suffix('s')).seconds
      expect(described_class::NIGHTLY_WAIT).to be < RecurringJob.concurrency_duration
    end
  end

  # The test-suite path, and the honest cost of it: inside an open
  # transaction the block runs with no snapshot of its own. Pinned so that
  # a change to the guard shows up as a failing spec rather than as specs
  # that still pass but no longer test what they claim to.
  describe 'with a transaction already open' do
    it 'runs the block without changing the transaction' do
      expect(ActiveRecord::Base.connection.transaction_open?).to be(true)

      modes = described_class.call { transaction_modes }

      # READ ONLY is the mode that proves it: SnapshotRead always sets it,
      # and nothing else in the app ever does, so finding it off means
      # nothing was applied here.
      expect(modes['read_only']).to eq('off')
      # The isolation level is compared against the session default rather
      # than against a literal. The test environment's default moves — it
      # runs at SERIALIZABLE ahead of production (config/database.yml, ADR
      # 0005) — and this example is about SnapshotRead not changing the
      # transaction, not about what the ambient level happens to be.
      expect(modes['isolation']).to eq(session_default_isolation)
    end

    it 'returns the block value' do
      expect(described_class.call { 42 }).to eq(42)
    end
  end
end
