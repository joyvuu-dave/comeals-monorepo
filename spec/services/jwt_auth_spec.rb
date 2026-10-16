# frozen_string_literal: true

require 'rails_helper'

RSpec.describe JwtAuth do
  include ActiveSupport::Testing::TimeHelpers

  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:resident) { create(:resident, community: community, unit: unit) }

  describe '.encode' do
    it 'returns the resident when given a freshly-issued token' do
      token = described_class.encode(resident)

      expect(described_class.authenticate(token)).to eq(resident)
    end

    it 'issues distinct tokens for different residents' do
      other = create(:resident, community: community, unit: unit)

      expect(described_class.encode(resident)).not_to eq(described_class.encode(other))
    end
  end

  describe '.authenticate' do
    it 'returns the resident for a token it issued' do
      expect(described_class.authenticate(described_class.encode(resident))).to eq(resident)
    end

    describe 'rejections' do
      it 'rejects nil and empty tokens' do
        expect(described_class.authenticate(nil)).to be_nil
        expect(described_class.authenticate('')).to be_nil
      end

      it 'rejects a malformed token' do
        expect(described_class.authenticate('not.a.jwt')).to be_nil
      end

      # The claims are good: signed with HS256 and our secret they are
      # accepted. So only the algorithm refuses the other two. iat keeps its
      # fraction of a second, as encode does. A whole-second iat falls
      # before the keys_valid_since the resident's create just set, and
      # that alone refused the token here, with or without an algorithm
      # check (2026-09-27, #119).
      it 'rejects a token signed with another algorithm, or with none at all' do
        claims = { 'resident_id' => resident.id, 'iat' => Time.current.to_f, 'iss' => described_class::ISSUER }
        ours = JWT.encode(claims, described_class.send(:secret), 'HS256')
        unsigned = JWT.encode(claims, nil, 'none')
        other_algorithm = JWT.encode(claims, described_class.send(:secret), 'HS512')

        expect(described_class.authenticate(ours)).to eq(resident)
        expect(described_class.authenticate(unsigned)).to be_nil
        expect(described_class.authenticate(other_algorithm)).to be_nil
      end

      it 'rejects a token with a tampered signature' do
        token = described_class.encode(resident)
        tampered = token.split('.').tap { |parts| parts[2] = 'bogus' }.join('.')

        expect(described_class.authenticate(tampered)).to be_nil
      end

      # The same claims signed with our secret are accepted, so only the
      # signature refuses the foreign token.
      it 'rejects a token signed with the wrong secret' do
        claims = { resident_id: resident.id, iat: Time.current.to_f, iss: 'comeals' }
        ours = JWT.encode(claims, described_class.send(:secret), 'HS256')
        foreign_token = JWT.encode(claims, 'different-secret', 'HS256')

        expect(described_class.authenticate(ours)).to eq(resident)
        expect(described_class.authenticate(foreign_token)).to be_nil
      end

      it 'rejects a token whose resident_id does not exist' do
        token = JWT.encode({ resident_id: 999_999, iat: Time.current.to_i, iss: 'comeals' },
                           described_class.send(:secret), 'HS256')

        expect(described_class.authenticate(token)).to be_nil
      end

      # The claims are otherwise good — the same claims with our issuer are
      # accepted — so the only thing refusing this token is the issuer check.
      # Mutant showed the old version of this example passing with issuer
      # verification switched off (2026-09-12): it never proved the check.
      it 'rejects a token with the wrong issuer, and only for the issuer' do
        claims = { resident_id: resident.id, iat: Time.current.to_f }
        ours = JWT.encode(claims.merge(iss: 'comeals'), described_class.send(:secret), 'HS256')
        foreign = JWT.encode(claims.merge(iss: 'somebody-else'), described_class.send(:secret), 'HS256')

        expect(described_class.authenticate(ours)).to eq(resident)
        expect(described_class.authenticate(foreign)).to be_nil
      end

      it 'rejects a token with no issuer claim at all' do
        token = JWT.encode({ resident_id: resident.id, iat: Time.current.to_f }, described_class.send(:secret), 'HS256')

        expect(described_class.authenticate(token)).to be_nil
      end
    end

    # A phone or a browser keeps a resident's token with no end date
    # (the top of app/services/jwt_auth.rb says why). So a token made
    # today must still sign in after every later change to this code.
    # If the key's name ('comeals-jwt-auth-v1') or length, the way Rails
    # turns secret_key_base into that key, the algorithm, the issuer or
    # a claim's name changed, every saved token would stop working at
    # once, and every resident would be signed out. The rule here is to
    # never break a current user.
    #
    # The token below was made once, on 2026-10-16, by JwtAuth.encode,
    # with the secret_key_base below, for resident 1000042 at
    # 1792108800.25 (2026-10-16 00:00:00.25 UTC). The test environment's
    # own secret_key_base is made at random for each checkout
    # (tmp/local_secret.txt), so the example sets a fixed one; production
    # signs with its own SECRET_KEY_BASE the same way. If this example
    # fails, do not make a new token to make it pass: the failure means
    # every token saved in production has stopped working.
    describe 'a token saved before today' do
      let(:saved_token) do
        'eyJhbGciOiJIUzI1NiJ9.eyJyZXNpZGVudF9pZCI6MTAwMDA0MiwiaWF0IjoxNzkyMTA4ODAwLjI1LCJpc3MiOiJjb21lYWxzIn0.' \
          'YSwca71mBtZubwkOb4PknjtTnRGvIKlFVGF8yhb-MXo'
      end

      before do
        allow(Rails.application).to receive(:secret_key_base)
          .and_return('a fixed secret_key_base, only for the saved-token example')
        # JwtAuth.secret keeps the key it made from the real
        # secret_key_base; forget it here, and again after the example.
        described_class.instance_variable_set(:@secret, nil)
      end

      after { described_class.instance_variable_set(:@secret, nil) }

      it 'still signs the resident in' do
        saved = create(:resident, id: 1_000_042, community: community, unit: unit)
        saved.update_column(:keys_valid_since, Time.zone.at(1_792_108_800))

        expect(described_class.authenticate(saved_token)).to eq(saved)
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
        # the inclusive boundary, so a future refactor that flips it fails here.
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

      # iat keeps its fraction of a second (RFC 7519 allows it), so a token
      # issued seven tenths of a second after a revocation is not confused
      # with one issued three tenths before it. Whole seconds would compare
      # equal here and let the revoked token through.
      it 'compares the issued-at time to the fraction of a second' do
        revoked_at = Time.zone.at(1_700_000_000.5)
        resident.update_column(:keys_valid_since, revoked_at)
        before = JWT.encode({ resident_id: resident.id, iat: 1_700_000_000.3, iss: 'comeals' },
                            described_class.send(:secret), 'HS256')
        after = JWT.encode({ resident_id: resident.id, iat: 1_700_000_000.7, iss: 'comeals' },
                           described_class.send(:secret), 'HS256')

        expect(described_class.authenticate(before)).to be_nil
        expect(described_class.authenticate(after)).to eq(resident)
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
        # Decode does not require iat, so the token gets past the signature
        # check. Then a missing iat reads as nil.to_f, which is 0.0, a time
        # in 1970. That is before every keys_valid_since (the column is NOT
        # NULL and defaults to the time the row was made), so the
        # keys_valid_since check is what refuses it.
        token = JWT.encode(
          { resident_id: resident.id, iss: 'comeals' },
          described_class.send(:secret), 'HS256'
        )

        expect(described_class.authenticate(token)).to be_nil
      end

      # Signed with our secret, so it gets past decode; there is no
      # resident to look up, and the answer is nil, not an error.
      it 'rejects a token missing the resident_id claim' do
        token = JWT.encode({ iat: Time.current.to_f, iss: 'comeals' }, described_class.send(:secret), 'HS256')

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

      # When decode names no algorithm, ruby-jwt takes the list in its own
      # settings. In jwt 3.3 that list is HS256 alone, the same as ours, so
      # under the gem's settings the example above passes with or without
      # the `algorithm:` in JwtAuth.decode. This one changes the gem's list
      # to HS512 and none for one example. A gem update that changes the
      # default list must not change which tokens are accepted here.
      it 'accepts only HS256 even when the gem would accept other algorithms by default' do
        claims = { 'resident_id' => resident.id, 'iat' => Time.current.to_f, 'iss' => described_class::ISSUER }
        ours = JWT.encode(claims, described_class.send(:secret), 'HS256')
        unsigned = JWT.encode(claims, nil, 'none')
        other_algorithm = JWT.encode(claims, described_class.send(:secret), 'HS512')
        gem_default = JWT.configuration.decode.algorithms

        begin
          JWT.configuration.decode.algorithms = %w[HS512 none]

          expect(described_class.authenticate(ours)).to eq(resident)
          expect(described_class.authenticate(unsigned)).to be_nil
          expect(described_class.authenticate(other_algorithm)).to be_nil
        ensure
          JWT.configuration.decode.algorithms = gem_default
        end
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
end
