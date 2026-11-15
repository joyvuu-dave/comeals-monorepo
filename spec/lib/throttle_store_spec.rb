# frozen_string_literal: true

require 'rails_helper'

# The store Rack::Attack counts in (#292). The SQL is ThrottleCount's
# (spec/models/throttle_count_spec.rb); this is the four calls
# Rack::Attack::Cache makes, turned into those.
RSpec.describe ThrottleStore do
  include ActiveSupport::Testing::TimeHelpers

  subject(:store) { described_class.new }

  let(:now) { Time.zone.parse('2026-04-01 12:00:30') }

  before { travel_to(now) }

  describe '.for' do
    it 'is the cache itself when the cache keeps nothing, so nothing is counted' do
      cache = ActiveSupport::Cache::NullStore.new

      expect(described_class.for(cache)).to be(cache)
    end

    it 'is a ThrottleStore when the cache keeps entries' do
      expect(described_class.for(ActiveSupport::Cache::MemoryStore.new)).to be_a(described_class)
    end
  end

  describe '#increment' do
    it 'returns the new count, and ends the window expires_in seconds from now' do
      expect(store.increment('k', 1, expires_in: 30)).to eq(1)
      expect(store.increment('k', 2, expires_in: 99)).to eq(3)
      expect(ThrottleCount.find('k').expires_at).to eq(now + 30.seconds)
    end

    it 'adds 1 when no amount is given' do
      store.increment('k', expires_in: 30)

      expect(store.increment('k', expires_in: 30)).to eq(2)
    end
  end

  describe '#write' do
    it 'sets the count, from a value Rack::Attack may pass as a string' do
      store.write('k', '5', expires_in: 30)

      expect([ThrottleCount.find('k').count, ThrottleCount.find('k').expires_at]).to eq([5, now + 30.seconds])
    end
  end

  describe '#read' do
    it 'is the count while the window lasts, and nil after' do
      store.increment('k', 4, expires_in: 30)

      expect(store.read('k')).to eq(4)
      travel_to(now + 30.seconds)
      expect(store.read('k')).to be_nil
    end
  end

  describe '#delete' do
    it 'forgets the count' do
      store.increment('k', 4, expires_in: 30)
      store.delete('k')

      expect(store.read('k')).to be_nil
    end
  end
end
