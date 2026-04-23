# frozen_string_literal: true

require 'rails_helper'

RSpec.describe JwtAuth do
  include ActiveSupport::Testing::TimeHelpers

  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:resident) { create(:resident, community: community, unit: unit) }

  describe '.encode and .authenticate (round trip)' do
    it 'returns the resident when given a freshly-issued token' do
      token = described_class.encode(resident)

      expect(described_class.authenticate(token)).to eq(resident)
    end

    it 'issues distinct tokens for different residents' do
      other = create(:resident, community: community, unit: unit)

      expect(described_class.encode(resident)).not_to eq(described_class.encode(other))
    end
  end

  describe '.authenticate rejections' do
    it 'rejects nil and empty tokens' do
      expect(described_class.authenticate(nil)).to be_nil
      expect(described_class.authenticate('')).to be_nil
    end

    it 'rejects a malformed token' do
      expect(described_class.authenticate('not.a.jwt')).to be_nil
    end

    it 'rejects a token with a tampered signature' do
      token = described_class.encode(resident)
      tampered = token.split('.').tap { |parts| parts[2] = 'bogus' }.join('.')

      expect(described_class.authenticate(tampered)).to be_nil
    end

    it 'rejects a token signed with the wrong secret' do
      foreign_token = JWT.encode({ resident_id: resident.id, iat: Time.current.to_i, iss: 'comeals' },
                                 'different-secret', 'HS256')

      expect(described_class.authenticate(foreign_token)).to be_nil
    end

    it 'rejects a token whose resident_id does not exist' do
      token = JWT.encode({ resident_id: 999_999, iat: Time.current.to_i, iss: 'comeals' },
                         described_class.send(:secret), 'HS256')

      expect(described_class.authenticate(token)).to be_nil
    end

    it 'rejects a token with the wrong issuer' do
      foreign_token = JWT.encode({ resident_id: resident.id, iat: Time.current.to_i, iss: 'somebody-else' },
                                 described_class.send(:secret), 'HS256')

      expect(described_class.authenticate(foreign_token)).to be_nil
    end
  end

  describe 'the keys_valid_since revocation lever' do
    it 'rejects a token whose iat is earlier than resident.keys_valid_since' do
      token = described_class.encode(resident)
      # Move the valid-since goalpost past the token's issued-at
      resident.update_column(:keys_valid_since, 1.hour.from_now)

      expect(described_class.authenticate(token)).to be_nil
    end

    it 'still accepts a freshly-issued token after the goalpost is bumped' do
      resident.update_column(:keys_valid_since, 1.hour.from_now)
      # Travel past the bumped goalpost, then issue and verify
      travel_to 2.hours.from_now do
        token = described_class.encode(resident)
        expect(described_class.authenticate(token)).to eq(resident)
      end
    end
  end
end
