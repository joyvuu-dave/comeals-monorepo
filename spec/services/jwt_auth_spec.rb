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

    it 'accepts a token whose iat equals keys_valid_since (inclusive boundary)' do
      # The check is `issued_at < keys_valid_since` → equality passes. Locks in
      # the inclusive boundary so a future refactor doesn't silently flip it.
      #
      # Boundary chosen as a round float so the Time → Float → Time round-trip
      # is lossless. A Time built with microsecond precision can drift by a
      # fractional microsecond through Float and trip the strict inequality.
      iat = 1_700_000_000.0
      token = JWT.encode(
        { resident_id: resident.id, iat: iat, iss: 'comeals' },
        described_class.send(:secret), 'HS256'
      )
      resident.update_column(:keys_valid_since, Time.zone.at(iat))

      expect(described_class.authenticate(token)).to eq(resident)
    end

    it 'rejects a token whose iat is a microsecond before keys_valid_since' do
      iat = 1_700_000_000.0
      earlier = iat - 0.000_001
      token = JWT.encode(
        { resident_id: resident.id, iat: earlier, iss: 'comeals' },
        described_class.send(:secret), 'HS256'
      )
      resident.update_column(:keys_valid_since, Time.zone.at(iat))

      expect(described_class.authenticate(token)).to be_nil
    end

    # Simulates the state after 20260423160000_add_keys_valid_since_to_residents.rb
    # runs against prod: every existing resident has keys_valid_since = created_at,
    # often months in the past. Post-deploy JWTs (iat = now) must pass.
    it 'accepts fresh JWTs for residents whose keys_valid_since was backfilled from created_at' do
      pre_deploy_resident = create(:resident, community: community, unit: unit,
                                              created_at: 6.months.ago)
      pre_deploy_resident.update_column(:keys_valid_since, pre_deploy_resident.created_at)

      token = described_class.encode(pre_deploy_resident)

      expect(described_class.authenticate(token)).to eq(pre_deploy_resident)
    end
  end

  describe 'payload hygiene' do
    it 'rejects a token missing the iat claim entirely' do
      # `claims['iat'].to_f` would become 0.0 (1970) — falls below any
      # keys_valid_since. Still, make this a first-class rejection path
      # rather than relying on the 1970 accident.
      token = JWT.encode(
        { resident_id: resident.id, iss: 'comeals' },
        described_class.send(:secret), 'HS256'
      )

      expect(described_class.authenticate(token)).to be_nil
    end

    it 'rejects a token whose iat is a non-numeric string' do
      # ruby-jwt validates iat at encode time, so we hand-build the token to
      # simulate a malicious/malformed client. On decode, to_f on a non-numeric
      # string returns 0.0 → effectively 1970, below any real keys_valid_since.
      header = Base64.urlsafe_encode64('{"alg":"HS256","typ":"JWT"}', padding: false)
      payload = Base64.urlsafe_encode64(
        { resident_id: resident.id, iat: 'not-a-number', iss: 'comeals' }.to_json,
        padding: false
      )
      signing_input = "#{header}.#{payload}"
      signature = Base64.urlsafe_encode64(
        OpenSSL::HMAC.digest('SHA256', described_class.send(:secret), signing_input),
        padding: false
      )
      bad_token = "#{signing_input}.#{signature}"

      expect(described_class.authenticate(bad_token)).to be_nil
    end

    it 'rejects a token for a resident who has been destroyed' do
      token = described_class.encode(resident)
      destroyed_id = resident.id
      resident.destroy!

      expect(described_class.authenticate(token)).to be_nil
      expect(Resident.find_by(id: destroyed_id)).to be_nil
    end
  end

  describe 'algorithm confusion attacks' do
    # Classic JWT CVE family: attacker swaps the alg header to bypass
    # signature verification. The ruby-jwt gem enforces algorithm: 'HS256'
    # in decode; these tests lock that enforcement in so a future accidental
    # relaxation (e.g. passing `algorithms: %w[HS256 none]`) fails CI.

    it "rejects a token whose alg header is 'none' and signature is empty" do
      # Hand-build: alg:none + empty signature. This is the original 2015 attack.
      header = Base64.urlsafe_encode64('{"alg":"none","typ":"JWT"}', padding: false)
      payload = Base64.urlsafe_encode64(
        { resident_id: resident.id, iat: Time.current.to_f, iss: 'comeals' }.to_json,
        padding: false
      )
      unsigned_token = "#{header}.#{payload}."

      expect(described_class.authenticate(unsigned_token)).to be_nil
    end

    it 'rejects a token signed with RS256 when we only accept HS256' do
      # If the server mistakenly verified with the HS256 code path but the
      # token carries alg: RS256, the shared secret would be misinterpreted
      # as an RSA public key. ruby-jwt's algorithm: parameter prevents this —
      # verify the rejection happens.
      rsa_private = OpenSSL::PKey::RSA.generate(2048)
      foreign_token = JWT.encode(
        { resident_id: resident.id, iat: Time.current.to_f, iss: 'comeals' },
        rsa_private, 'RS256'
      )

      expect(described_class.authenticate(foreign_token)).to be_nil
    end
  end
end
