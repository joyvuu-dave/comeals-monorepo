# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('lib/database_pool_check')

# The boot check that keeps the pool and the thread count from drifting
# apart. config/database.yml sets them separately on purpose, which is
# what makes it easy to raise one and forget the other — and a pool
# smaller than the threads turns every busy moment into a 503.
RSpec.describe DatabasePoolCheck do
  describe '.call' do
    it 'accepts a pool with one connection per thread plus one for the trim thread' do
      expect { described_class.call(pool: 2, threads: 1) }.not_to raise_error
      expect { described_class.call(pool: 9, threads: 8) }.not_to raise_error
    end

    it 'accepts a pool larger than the rule asks for' do
      expect { described_class.call(pool: 20, threads: 1) }.not_to raise_error
    end

    it 'refuses a pool with no room for the trim thread' do
      expect { described_class.call(pool: 1, threads: 1) }
        .to raise_error(/pool of 1 is too small for 1 Puma thread/)
    end

    it 'refuses the drift it exists for: threads raised, pool left behind' do
      expect { described_class.call(pool: 2, threads: 5) }
        .to raise_error(/Set RAILS_DB_POOL to at least 6/)
    end
  end

  describe '.verify!' do
    it 'passes for this process, which is how every environment boots' do
      expect { described_class.verify! }.not_to raise_error
    end

    it 'reads the threads from the variable config/puma.rb reads' do
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with('RAILS_MAX_THREADS', 1).and_return('40')

      expect { described_class.verify! }.to raise_error(/too small for 40 Puma thread/)
    end
  end
end
