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

  describe 'token generation (has_secure_token)' do
    it 'generates a unique token on creation' do
      resident = create(:resident, community: community, unit: unit)
      key = resident.keys.first

      expect(key.token).to be_present
      expect(key.token.length).to be > 20
    end

    # The login fallback looks a person up by token alone
    # (ApiController#resolve_current_session), so one token must never
    # belong to two people. The model has no uniqueness rule; the unique
    # index is what holds it.
    it 'refuses a second key with a token that is already taken, at the database' do
      taken = create(:resident, community: community, unit: unit).keys.first.token
      other = create(:resident, community: community, unit: unit)

      expect { described_class.create!(identity: other, token: taken) }
        .to raise_error(ActiveRecord::RecordNotUnique, /index_keys_on_token/)
    end
  end

  describe 'associations' do
    it 'is polymorphic — belongs to identity' do
      resident = create(:resident, community: community, unit: unit)
      key = resident.keys.first

      expect(key.identity_type).to eq('Resident')
      expect(key.identity).to eq(resident)
    end

    # No code makes Key rows any more, but a person may still hold old
    # pre-JWT tokens from more than one device.
    it 'allows a resident to hold several legacy pre-JWT keys' do
      resident = create(:resident, community: community, unit: unit)
      resident.keys.create!
      resident.keys.create!

      expect(resident.keys.count).to eq(3) # factory creates one; we added two
      expect(resident.keys.pluck(:token).uniq.size).to eq(3)
    end
  end
end
