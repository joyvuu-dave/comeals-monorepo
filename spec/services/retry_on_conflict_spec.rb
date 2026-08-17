# frozen_string_literal: true

require 'rails_helper'

RSpec.describe RetryOnConflict do
  # The real waits are milliseconds, but there is no reason to spend them.
  before { allow(described_class).to receive(:sleep) }

  # The guard against retrying inside an open transaction is the whole
  # correctness argument, and under transactional fixtures a transaction is
  # always open. So the retrying cases need it off.
  describe 'at the outermost transaction' do
    include_context 'with no test transaction'

    it 'returns the block value when nothing conflicts' do
      expect(described_class.call { 42 }).to eq(42)
    end

    it 'runs the block once when nothing conflicts' do
      calls = 0
      described_class.call { calls += 1 }

      expect(calls).to eq(1)
    end

    it 'runs the block again after a serialization failure' do
      calls = 0
      result = described_class.call do
        calls += 1
        raise ActiveRecord::SerializationFailure, 'conflict' if calls < 2

        'second time'
      end

      expect(calls).to eq(2)
      expect(result).to eq('second time')
    end

    # Deadlocks are the same shape of problem with the same answer, and
    # PostgreSQL raises them more often at SERIALIZABLE.
    it 'runs the block again after a deadlock' do
      calls = 0
      described_class.call do
        calls += 1
        raise ActiveRecord::Deadlocked, 'deadlock' if calls < 2
      end

      expect(calls).to eq(2)
    end

    it 'gives up after MAX_ATTEMPTS and re-raises' do
      calls = 0

      expect do
        described_class.call do
          calls += 1
          raise ActiveRecord::SerializationFailure, 'conflict'
        end
      end.to raise_error(ActiveRecord::SerializationFailure)

      expect(calls).to eq(described_class::MAX_ATTEMPTS)
    end

    it 'does not retry an ordinary error' do
      calls = 0

      expect do
        described_class.call do
          calls += 1
          raise ActiveRecord::RecordInvalid
        end
      end.to raise_error(ActiveRecord::RecordInvalid)

      expect(calls).to eq(1)
    end

    # A lock wait refused by lock_timeout (config/database.yml) must not be
    # retried here: the lock was held for the full 5 seconds, so it is
    # likely still held, and these delays are milliseconds. The controllers
    # rescue it and answer "try again" instead
    # (Api::V1::MealsController#with_meal_lock).
    it 'does not retry a lock wait timeout' do
      calls = 0

      expect do
        described_class.call do
          calls += 1
          raise ActiveRecord::LockWaitTimeout, 'canceling statement due to lock timeout'
        end
      end.to raise_error(ActiveRecord::LockWaitTimeout)

      expect(calls).to eq(1)
    end

    # Two transactions that conflicted and then waited the same length of
    # time tend to conflict again, so the wait grows and carries jitter.
    it 'waits longer before each retry' do
      delays = []
      allow(described_class).to receive(:sleep) { |seconds| delays << seconds }

      begin
        described_class.call { raise ActiveRecord::SerializationFailure, 'conflict' }
      rescue ActiveRecord::SerializationFailure
        nil
      end

      expect(delays.size).to eq(described_class::MAX_ATTEMPTS - 1)
      expect(delays.last).to be > delays.first
    end

    # Counting retries is the point. An error tracker sees a crash; it never
    # sees the retry that stopped one, and "how often is this firing" is the
    # number that says whether the change is behaving.
    it 'reports each retry through Rails.error' do
      allow(Rails.error).to receive(:report)
      calls = 0
      described_class.call do
        calls += 1
        raise ActiveRecord::SerializationFailure, 'conflict' if calls < 2
      end

      expect(Rails.error).to have_received(:report).once.with(
        an_instance_of(ActiveRecord::SerializationFailure),
        hash_including(handled: true, severity: :warning)
      )
    end
  end

  # Retrying inside someone else's transaction cannot work: PostgreSQL has
  # already refused every later statement in it. Re-raise and let the owner
  # of the outermost transaction decide.
  describe 'inside an open transaction' do
    it 'runs the block' do
      expect(described_class.call { 42 }).to eq(42)
    end

    it 'does not retry' do
      calls = 0

      expect do
        described_class.call do
          calls += 1
          raise ActiveRecord::SerializationFailure, 'conflict'
        end
      end.to raise_error(ActiveRecord::SerializationFailure)

      expect(calls).to eq(1)
    end
  end
end
