# frozen_string_literal: true

require 'rails_helper'

# Production switched from memcached (dalli/MemCachier) to solid_cache, which
# keeps entries in a Postgres table instead of a separate memcached server.
#
# The app has exactly four cache call sites and they use five methods between
# them: fetch with expires_in (the calendar, CommunitiesController#calendar),
# read and write (MealsController#show_cooks), and delete (the invalidation in
# Community#invalidate_calendar_cache and Meal#trigger_pusher). This spec runs
# each of those against a real SolidCache::Store, with the kind of value the
# app actually stores — a serializer's as_json output, which is nested hashes
# and arrays, not a flat string.
RSpec.describe SolidCache::Store do
  include ActiveSupport::Testing::TimeHelpers

  subject(:cache) { described_class.new(namespace: "solid-cache-spec-#{SecureRandom.hex(4)}") }

  # Shaped like what ActiveModelSerializers hands back: string keys, nested
  # arrays and hashes, and a BigDecimal, since money in this app is never a
  # Float (see CLAUDE.md).
  let(:serialized_payload) do
    {
      'id' => 1,
      'date' => '2026-07-24',
      'meals' => [
        { 'id' => 7, 'cooks' => %w[Ada Grace], 'cost' => BigDecimal('42.50000000') },
        { 'id' => 8, 'cooks' => [], 'cost' => nil }
      ]
    }
  end

  it 'writes into the solid_cache_entries table' do
    expect { cache.write('some-key', 'some value') }
      .to change(SolidCache::Entry, :count).by(1)
  end

  describe 'read and write — the show_cooks path' do
    it 'round-trips a serialized payload unchanged' do
      cache.write('meal-7', serialized_payload)

      expect(cache.read('meal-7')).to eq(serialized_payload)
    end

    it 'keeps BigDecimal a BigDecimal rather than a Float' do
      cache.write('meal-7', serialized_payload)

      cost = cache.read('meal-7')['meals'].first['cost']

      expect(cost).to be_a(BigDecimal)
      expect(cost).to eq(BigDecimal('42.50000000'))
    end

    it 'returns nil for a key that was never written' do
      expect(cache.read('meal-does-not-exist')).to be_nil
    end

    it 'overwrites a key rather than appending a second entry' do
      cache.write('meal-7', 'first')
      cache.write('meal-7', 'second')

      expect(cache.read('meal-7')).to eq('second')
    end

    it 'keeps separate keys separate' do
      cache.write('meal-7', 'seven')
      cache.write('meal-8', 'eight')

      expect(cache.read('meal-7')).to eq('seven')
      expect(cache.read('meal-8')).to eq('eight')
    end
  end

  describe 'fetch with expires_in — the calendar path' do
    it 'runs the block on a miss and returns its value' do
      result = cache.fetch('community-1-calendar-2026-7', expires_in: 1.hour) { serialized_payload }

      expect(result).to eq(serialized_payload)
    end

    it 'skips the block on a hit' do
      cache.fetch('community-1-calendar-2026-7', expires_in: 1.hour) { 'computed once' }

      expect { |b| cache.fetch('community-1-calendar-2026-7', expires_in: 1.hour, &b) }
        .not_to yield_control
    end

    it 'recomputes once the entry has expired' do
      cache.fetch('community-1-calendar-2026-7', expires_in: 1.hour) { 'stale' }

      travel 2.hours do
        result = cache.fetch('community-1-calendar-2026-7', expires_in: 1.hour) { 'fresh' }

        expect(result).to eq('fresh')
      end
    end
  end

  describe 'delete — the invalidation path' do
    it 'removes the entry so the next read misses' do
      cache.write('community-1-calendar-2026-7', serialized_payload)

      cache.delete('community-1-calendar-2026-7')

      expect(cache.read('community-1-calendar-2026-7')).to be_nil
    end

    it 'makes the next fetch recompute' do
      cache.fetch('community-1-calendar-2026-7', expires_in: 1.hour) { 'before' }
      cache.delete('community-1-calendar-2026-7')

      result = cache.fetch('community-1-calendar-2026-7', expires_in: 1.hour) { 'after' }

      expect(result).to eq('after')
    end

    it 'is a no-op on a key that is not there' do
      expect { cache.delete('never-written') }.not_to raise_error
    end

    it 'leaves other keys alone' do
      cache.write('community-1-calendar-2026-7', 'july')
      cache.write('community-1-calendar-2026-8', 'august')

      cache.delete('community-1-calendar-2026-7')

      expect(cache.read('community-1-calendar-2026-8')).to eq('august')
    end
  end

  describe 'namespacing' do
    # config/solid_cache.yml namespaces by Rails.env, so a staging or console
    # session against the same database cannot read production's entries.
    it 'does not leak values between two stores with different namespaces' do
      other = described_class.new(namespace: "solid-cache-spec-other-#{SecureRandom.hex(4)}")

      cache.write('meal-7', 'mine')

      expect(other.read('meal-7')).to be_nil
    end
  end
end
