# frozen_string_literal: true

require 'rails_helper'

# Rack::Attack's request counts (#292). Two requests from one address at
# the same moment are in spec/concurrency/shared_address_spec.rb.
# == Schema Information
#
# Table name: throttle_counts
#
#  count      :integer          not null
#  expires_at :datetime         not null
#  key        :text             not null, primary key
#
# Indexes
#
#  index_throttle_counts_on_expires_at  (expires_at)
#
RSpec.describe ThrottleCount do
  let(:now) { Time.zone.parse('2026-04-01 12:00:30') }
  let(:window_end) { now + 30.seconds }

  def row(key)
    described_class.find(key).then { |found| [found.count, found.expires_at] }
  end

  describe '.add' do
    it 'starts a new key at the amount, with the window end it was given' do
      expect(described_class.add('k', 1, expires_at: window_end, now: now)).to eq(1)
      expect(row('k')).to eq([1, window_end])
    end

    it 'adds to a count whose window has not ended, and keeps that window' do
      described_class.add('k', 1, expires_at: window_end, now: now)

      expect(described_class.add('k', 2, expires_at: window_end + 1.minute, now: now + 1.second)).to eq(3)
      expect(row('k')).to eq([3, window_end])
    end

    it 'starts a count again when its window has ended, with the new window end' do
      described_class.add('k', 5, expires_at: window_end, now: now)

      expect(described_class.add('k', 1, expires_at: window_end + 1.minute, now: window_end)).to eq(1)
      expect(row('k')).to eq([1, window_end + 1.minute])
    end

    it 'adds to the row another request added between its UPDATE and its INSERT' do
      allow(described_class).to receive(:count_from).and_wrap_original do |original, sql, values|
        described_class.set('k', 4, expires_at: window_end) if sql == described_class::INSERT_NEW
        original.call(sql, values)
      end

      expect(described_class.add('k', 1, expires_at: window_end, now: now)).to eq(5)
    end

    it 'keeps counts for other keys apart' do
      described_class.add('a', 1, expires_at: window_end, now: now)

      expect(described_class.add('b', 1, expires_at: window_end, now: now)).to eq(1)
    end
  end

  describe '.set' do
    it 'writes a new key' do
      described_class.set('k', 4, expires_at: window_end)

      expect(row('k')).to eq([4, window_end])
    end

    it 'replaces the count and the window end of a key that has a row' do
      described_class.add('k', 9, expires_at: window_end, now: now)
      described_class.set('k', 2, expires_at: window_end + 1.minute)

      expect(row('k')).to eq([2, window_end + 1.minute])
    end
  end

  describe '.current' do
    before { described_class.add('k', 7, expires_at: window_end, now: now) }

    it 'is the count while its window has not ended' do
      expect(described_class.current('k', now: window_end - 1.second)).to eq(7)
    end

    it 'is nil once the window has ended' do
      expect(described_class.current('k', now: window_end)).to be_nil
    end

    it 'is nil for a key with no row' do
      expect(described_class.current('other', now: now)).to be_nil
    end
  end

  describe '.forget' do
    it 'deletes that key only' do
      described_class.add('a', 1, expires_at: window_end, now: now)
      described_class.add('b', 1, expires_at: window_end, now: now)

      described_class.forget('a')

      expect(described_class.pluck(:key)).to eq(['b'])
    end
  end

  describe '.delete_expired' do
    it 'deletes the rows whose window has ended, and says how many' do
      described_class.add('ended', 1, expires_at: now - 1.second, now: now - 1.minute)
      described_class.add('ends now', 1, expires_at: now, now: now - 1.minute)
      described_class.add('open', 1, expires_at: now + 1.second, now: now - 1.minute)

      expect(described_class.delete_expired(now: now)).to eq(2)
      expect(described_class.pluck(:key)).to eq(['open'])
    end
  end

  describe 'the isolation level' do
    def level
      described_class.send(:read_committed) { described_class.connection.select_value('SHOW transaction_isolation') }
    end

    it 'joins an open transaction at its level, since PostgreSQL cannot change it' do
      expect(level).to eq('serializable')
    end

    context 'with no transaction open' do
      include_context 'with no test transaction'

      it 'runs in a transaction of its own at READ COMMITTED' do
        expect(level).to eq('read committed')
      end
    end
  end
end
