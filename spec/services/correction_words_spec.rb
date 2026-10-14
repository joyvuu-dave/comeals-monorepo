# frozen_string_literal: true

require 'rails_helper'

# The sentences for each edit a correction records (MealCorrecting::Edits),
# which the admin pages and the API preview show.
RSpec.describe CorrectionWords do
  let(:community) { create(:community) }
  let(:alice) { create(:resident, community: community, name: 'Alice') }
  let(:residents) { { alice.id => alice } }

  def words(what, from, to, resident_id: alice.id)
    described_class.edit({ 'what' => what, 'resident_id' => resident_id, 'from' => from, 'to' => to }, residents)
  end

  def cost(amount, no_cost: false)
    { 'amount' => amount, 'no_cost' => no_cost }
  end

  describe '.edit' do
    it 'says what changed in a cook\'s cost' do
      expect([words('cost', cost('170.0'), cost('17.0')),
              words('cost', cost('0.0'), cost('0.0', no_cost: true)),
              words('cost', nil, cost('12.5')),
              words('cost', cost('0.0', no_cost: true), nil)])
        .to eq(["Changed Alice's cost from $170.00 to $17.00.",
                "Changed Alice's cost from blank to No cost.",
                'Added Alice as a cook ($12.50).',
                'Removed Alice as a cook (No cost).'])
    end

    it 'says what changed in a sign-up' do
      expect([words('eater', nil, 2), words('eater', 1, nil), words('eater', 2, 1)])
        .to eq(['Signed up Alice (Adult).', "Removed Alice's sign-up (Child).",
                "Changed Alice's price from Adult to Child."])
    end

    it 'says which guest was added or removed' do
      expect([words('guest', nil, 1), words('guest', 2, nil)])
        .to eq(['Added a guest of Alice (Child).', 'Removed a guest of Alice (Adult).'])
    end

    it 'names a resident it was not given by id, and shows an edit it does not know as stored' do
      expect(words('eater', nil, 2, resident_id: 999)).to eq('Signed up Resident #999 (Adult).')
      expect(words('cap', '4.5', '5.0')).to eq('cap: "4.5" to "5.0"')
    end
  end

  describe '.residents_named_in' do
    it 'loads every resident the corrections\' edits name, in one query' do
      bob = create(:resident, community: community, name: 'Bob')
      corrections = [MealCorrection.new(edits: [{ 'resident_id' => alice.id }, { 'resident_id' => bob.id }]),
                     MealCorrection.new(edits: [{ 'resident_id' => alice.id }])]

      expect(described_class.residents_named_in(corrections)).to eq(alice.id => alice, bob.id => bob)
    end
  end
end
