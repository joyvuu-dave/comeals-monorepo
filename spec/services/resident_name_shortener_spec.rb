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

  it 'returns empty string for blank name' do
    expect(described_class.short('')).to eq('')
    expect(described_class.short(nil)).to eq('')
  end
end
