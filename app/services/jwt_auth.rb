# typed: true
# frozen_string_literal: true

# Stateless authentication using JSON Web Tokens.
#
# Each login issues a JWT signed with a key derived from secret_key_base.
# The token holds the resident id, the time it was made (`iat`), and the
# resident's `keys_valid_since` as it was when the token was made, in
# microseconds. A token is good while its signature checks and the
# resident's `keys_valid_since` still has that same value. There is no
# database row per session, and no lookup by token string.
#
# Tokens made before 2026-11-03 have no `keys_valid_since` claim. They
# are still saved on phones and browsers, and the rule is never to sign a
# current user out, so they keep the old rule: their `iat` must not be
# earlier than `keys_valid_since`. That rule alone let a sign-in with the
# old password, made while a password change was saved but not yet
# committed, keep working after the change (#265): the sign-in read the
# old digest, and its `iat` was later than the new `keys_valid_since`.
#
# Revocation comes from bumping `keys_valid_since`:
#   - Password change (via Resident#revoke_all_sessions_if_password_changed)
#   - Any future admin "force sign-out" lever
#
# A stolen JWT is valid until one of those fires. We accept that trade-off
# in exchange for infinite sessions at zero per-session storage — see
# earlier architectural discussion.
module JwtAuth
  ALGORITHM = 'HS256'
  ISSUER    = 'comeals'

  class << self
    # Sign and return a JWT string for the given resident. `iat` is stored
    # with fractional-second precision so the comparison against
    # keys_valid_since (a microsecond-precision datetime) doesn't round trip
    # through a lossy second boundary. Fractional NumericDate is permitted
    # by RFC 7519.
    def encode(resident)
      payload = {
        resident_id: resident.id,
        iat: Time.current.to_f,
        iss: ISSUER,
        keys_valid_since: microseconds(T.must(resident.keys_valid_since))
      }
      JWT.encode(payload, secret, ALGORITHM)
    end

    # Verify `token` and return the authenticated Resident, or nil for any
    # failure (bad signature, wrong issuer, revoked by keys_valid_since,
    # unknown resident_id, malformed input).
    def authenticate(token)
      return nil if token.blank?

      claims = decode(token)
      return nil unless claims

      resident = Resident.find_by(id: claims['resident_id'])
      return nil unless resident

      return nil unless still_valid?(claims, T.must(resident.keys_valid_since))

      resident
    end

    private

    # A token with a keys_valid_since claim is good only while the column
    # still has that value. One without it (made before #265) keeps the
    # old rule: made at or after keys_valid_since.
    def still_valid?(claims, keys_valid_since)
      made_with = claims['keys_valid_since']
      return made_with == microseconds(keys_valid_since) unless made_with.nil?

      Time.zone.at(claims['iat'].to_f) >= keys_valid_since
    end

    # The time in whole microseconds since 1970, which is what the column
    # keeps. Two values are equal only when the times are the same to the
    # microsecond. Whole numbers, so there is no Float rounding.
    def microseconds(time)
      (time.to_i * 1_000_000) + time.usec
    end

    def decode(token)
      payload, _header = JWT.decode(
        token, secret, true,
        algorithm: ALGORITHM,
        iss: ISSUER,
        verify_iss: true
      )
      payload
    rescue JWT::DecodeError
      nil
    end

    # Derive a dedicated signing key from secret_key_base so the raw master
    # key never leaves the KeyGenerator boundary. Memoized per process.
    def secret
      @secret ||= Rails.application.key_generator.generate_key('comeals-jwt-auth-v1', 32) # rubocop:disable ThreadSafety/ClassInstanceVariable -- the one class-level memo, argued for in spec/concurrency/process_wide_state_spec.rb
    end
  end
end
