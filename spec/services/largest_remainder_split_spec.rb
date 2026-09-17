# frozen_string_literal: true

require 'rails_helper'

RSpec.describe LargestRemainderSplit do
  describe 'the worked example in MODELS.md' do
    # $60 across three adults and a half-price child: 6,000,000,000 units
    # across weights 2, 2, 2, 1.
    it 'hands the leftover unit to the earliest of the shares that lost the most' do
      shares = described_class.call(6_000_000_000, [2, 2, 2, 1])

      expect(shares).to eq([1_714_285_715, 1_714_285_714, 1_714_285_714, 857_142_857])
      expect(shares.sum).to eq(6_000_000_000)
    end
  end

  describe 'the rule' do
    it 'gives back exactly the total' do
      expect(described_class.call(100, [3, 3, 3]).sum).to eq(100)
      expect(described_class.call(1, [1, 1, 1]).sum).to eq(1)
      expect(described_class.call(0, [1, 2]).sum).to eq(0)
    end

    it 'splits an even total evenly, with nothing left over to hand out' do
      expect(described_class.call(90, [1, 2])).to eq([30, 60])
    end

    it 'breaks a tie by position, earlier first' do
      expect(described_class.call(1, [1, 1, 1])).to eq([1, 0, 0])
      expect(described_class.call(2, [1, 1, 1])).to eq([1, 1, 0])
    end

    it 'ranks by what each share lost, not by its weight' do
      # 10 across weights 1 and 3: exact shares 2.5 and 7.5, both lose a
      # half, so the tie goes to the first. 10 across 1 and 2: exact 3.33
      # and 6.67, and the second lost more.
      expect(described_class.call(10, [1, 3])).to eq([3, 7])
      expect(described_class.call(10, [1, 2])).to eq([3, 7])
    end

    it 'never gives a leftover unit to a share with weight zero' do
      expect(described_class.call(2, [0, 1, 1, 1])).to eq([0, 1, 1, 0])
    end

    it 'never gives a leftover unit to a share whose exact share is whole' do
      # 5 across 2, 1, 1: exact 2.5, 1.25, 1.25. Whole units 2, 1, 1; the
      # one leftover goes to the first (lost .5), never to a share that
      # lost nothing.
      expect(described_class.call(5, [2, 1, 1])).to eq([3, 1, 1])
      expect(described_class.call(4, [2, 1, 1])).to eq([2, 1, 1])
    end

    it 'keeps every share within one unit of its exact share' do
      rng = Random.new(85)
      200.times do
        weights = Array.new(rng.rand(1..12)) { rng.rand(0..3) }
        next if weights.sum.zero?

        total = rng.rand(0..1_000_000_000)
        shares = described_class.call(total, weights)

        expect(shares.sum).to eq(total)
        whole = weights.sum
        shares.zip(weights).each do |share, weight|
          # |share - total * weight / whole| < 1, with everything times whole.
          expect(((share * whole) - (total * weight)).abs).to be < whole
        end
      end
    end

    it 'is a function of its input' do
      first = described_class.call(1234, [1, 2, 3])
      again = described_class.call(1234, [1, 2, 3])

      expect(again).to eq(first)
    end
  end

  describe 'refusals' do
    it 'refuses a negative total' do
      expect { described_class.call(-1, [1]) }.to raise_error(ArgumentError, /negative/)
    end

    it 'refuses no shares' do
      expect { described_class.call(5, []) }.to raise_error(ArgumentError, /no shares/)
    end

    it 'refuses a negative weight' do
      expect { described_class.call(5, [1, -1]) }.to raise_error(ArgumentError, /negative/)
    end

    it 'refuses weights that are all zero' do
      expect { described_class.call(5, [0, 0]) }.to raise_error(ArgumentError, /every weight is zero/)
    end
  end
end
