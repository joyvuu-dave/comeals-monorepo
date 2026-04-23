# frozen_string_literal: true

# == Schema Information
#
# Table name: keys
#
#  id            :bigint           not null, primary key
#  identity_type :string           not null
#  token         :string           not null
#  created_at    :datetime         not null
#  updated_at    :datetime         not null
#  identity_id   :bigint           not null
#
# Indexes
#
#  index_keys_on_identity_type_and_identity_id  (identity_type,identity_id)
#  index_keys_on_token                          (token) UNIQUE
#
require 'rails_helper'

RSpec.describe Key do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }

  describe '#set_token' do
    it 'generates a unique token on creation' do
      resident = create(:resident, community: community, unit: unit)
      key = resident.keys.first

      expect(key.token).to be_present
      expect(key.token.length).to be > 20
    end

    it 'generates unique tokens across keys' do
      r1 = create(:resident, community: community, unit: unit)
      r2 = create(:resident, community: community, unit: unit)

      expect(r1.keys.first.token).not_to eq(r2.keys.first.token)
    end
  end

  describe 'associations' do
    it 'is polymorphic — belongs to identity' do
      resident = create(:resident, community: community, unit: unit)
      key = resident.keys.first

      expect(key.identity_type).to eq('Resident')
      expect(key.identity).to eq(resident)
    end

    it 'allows a resident to hold multiple concurrent sessions' do
      resident = create(:resident, community: community, unit: unit)
      resident.keys.create!
      resident.keys.create!

      expect(resident.keys.count).to eq(3) # factory creates one; we added two
      expect(resident.keys.pluck(:token).uniq.size).to eq(3)
    end
  end
end
