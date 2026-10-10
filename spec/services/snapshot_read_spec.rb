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

    # Another session's SERIALIZABLE transaction, open for the whole block.
    # A DEFERRABLE transaction waits for every one of these on the server,
    # in every database, before it takes its first snapshot. So this one
    # stands in for a write that another worktree or a mutant worker left
    # open. It is a raw PG connection because the test pool has only one.
    def with_serializable_transaction_open_elsewhere
      db = ActiveRecord::Base.connection_db_config.configuration_hash
      other = PG.connect(host: db[:host], port: db[:port], user: db[:username],
                         password: db[:password], dbname: db[:database])
      other.exec('BEGIN ISOLATION LEVEL SERIALIZABLE')
      # Its first snapshot is what puts it on the server's list.
      other.exec('SELECT 1')
      yield
    ensure
      # Closing the session rolls the transaction back. It wrote nothing.
      other&.close
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
  end

  # The test-suite path, and the honest cost of it: inside an open
  # transaction the block runs with no snapshot of its own. Pinned so that
  # a change to the guard shows up as a failing spec rather than as specs
  # that quietly stop testing what they claim to.
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
