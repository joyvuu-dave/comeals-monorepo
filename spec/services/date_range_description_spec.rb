# frozen_string_literal: true

require 'rails_helper'

# One format for every named period (rotation titles, settlement statement
# headings): month names, and no repeated year or month when they match.
# The dash is an en dash — closed up between two day numbers, spaced when
# either side contains a space.
RSpec.describe DateRangeDescription do
  it 'returns an empty string when there are no dates' do
    expect(described_class.for(nil, nil)).to eq('')
  end

  it 'shows a single day once' do
    day = Date.new(2026, 7, 16)

    expect(described_class.for(day, day)).to eq('Jul 16, 2026')
  end

  it 'names the month once when both days are in it' do
    expect(described_class.for(Date.new(2026, 7, 16), Date.new(2026, 7, 28)))
      .to eq('Jul 16–28, 2026')
  end

  it 'names the year once when both days are in it' do
    expect(described_class.for(Date.new(2026, 7, 16), Date.new(2026, 8, 13)))
      .to eq('Jul 16 – Aug 13, 2026')
  end

  it 'gives each side its own year when they differ' do
    expect(described_class.for(Date.new(2026, 12, 14), Date.new(2027, 1, 11)))
      .to eq('Dec 14, 2026 – Jan 11, 2027')
  end
end
