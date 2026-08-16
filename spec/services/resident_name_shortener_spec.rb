# frozen_string_literal: true

require 'rails_helper'

# The shortest still-unique form of a resident's name. Moved from
# ApplicationHelper (#51); Current.reset in rails_helper clears the
# per-request name cache between examples.
RSpec.describe ResidentNameShortener do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }

  it 'returns the full name when it has no last name' do
    create(:resident, community: community, unit: unit, name: 'Cher')
    expect(described_class.short('Cher')).to eq('Cher')
  end

  it 'returns just the first name when it is unique' do
    create(:resident, community: community, unit: unit, name: 'Alice Smith')
    expect(described_class.short('Alice Smith')).to eq('Alice')
  end

  it 'returns first name + last initial when first name is not unique' do
    create(:resident, community: community, unit: unit, name: 'Alice Smith')
    create(:resident, community: community, unit: unit, name: 'Alice Jones')
    expect(described_class.short('Alice Smith')).to eq('Alice S')
    expect(described_class.short('Alice Jones')).to eq('Alice J')
  end

  it 'uses full last name when initial is also ambiguous' do
    create(:resident, community: community, unit: unit, name: 'Alice Smith')
    create(:resident, community: community, unit: unit, name: 'Alice Springer')
    expect(described_class.short('Alice Smith')).to eq('Alice Smith')
    expect(described_class.short('Alice Springer')).to eq('Alice Springer')
  end

  it 'uses the last word as the last name, skipping middle names' do
    create(:resident, community: community, unit: unit, name: 'Mary Jane Smith')
    create(:resident, community: community, unit: unit, name: 'Mary Jane Jones')
    expect(described_class.short('Mary Jane Smith')).to eq('Mary S')
    expect(described_class.short('Mary Jane Jones')).to eq('Mary J')
  end

  it 'falls back to the whole name, middle names included' do
    create(:resident, community: community, unit: unit, name: 'Mary Jane Smith')
    create(:resident, community: community, unit: unit, name: 'Mary Ann Smyth')
    expect(described_class.short('Mary Jane Smith')).to eq('Mary Jane Smith')
    expect(described_class.short('Mary Ann Smyth')).to eq('Mary Ann Smyth')
  end

  it 'compares names case-insensitively, like name uniqueness does' do
    create(:resident, community: community, unit: unit, name: 'alice smith')
    create(:resident, community: community, unit: unit, name: 'Alice Jones')
    expect(described_class.short('alice smith')).to eq('alice s')
    expect(described_class.short('Alice Jones')).to eq('Alice J')
  end

  it 'does not treat a bare first name as sharing a last initial' do
    create(:resident, community: community, unit: unit, name: 'Alice')
    create(:resident, community: community, unit: unit, name: 'Alice Smith')
    expect(described_class.short('Alice')).to eq('Alice')
    expect(described_class.short('Alice Smith')).to eq('Alice S')
  end

  it 'returns empty string for blank name' do
    expect(described_class.short('')).to eq('')
    expect(described_class.short(nil)).to eq('')
  end
end
