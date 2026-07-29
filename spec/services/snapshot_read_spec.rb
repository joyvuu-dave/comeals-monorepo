# frozen_string_literal: true

require 'rails_helper'

RSpec.describe SnapshotRead do
  def transaction_modes
    ActiveRecord::Base.connection.select_one(
      "SELECT current_setting('transaction_isolation') AS isolation,
              current_setting('transaction_read_only') AS read_only,
              current_setting('transaction_deferrable') AS deferrable"
    )
  end

  def session_default_isolation
    ActiveRecord::Base.connection.select_value('SHOW default_transaction_isolation')
  end

  # The real path. Transactional fixtures would leave a transaction already
  # open, which is the case SnapshotRead deliberately skips, so this group
  # runs without them. It creates no rows, so there is nothing to clean up.
  describe 'with no transaction already open' do
    self.use_transactional_tests = false

    it 'opens the transaction SERIALIZABLE READ ONLY DEFERRABLE' do
      modes = described_class.call { transaction_modes }

      expect(modes['isolation']).to eq('serializable')
      expect(modes['read_only']).to eq('on')
      # DEFERRABLE is what makes this transaction unable to fail with a
      # serialization error, so it needs no retry. It only takes effect
      # together with the other two.
      expect(modes['deferrable']).to eq('on')
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
