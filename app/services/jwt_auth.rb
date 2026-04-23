# frozen_string_literal: true

# Stateless authentication using JSON Web Tokens.
#
# Each login issues a JWT signed with a key derived from secret_key_base.
# The token embeds the resident id and issued-at timestamp. Validation
# consists of verifying the signature and confirming the `iat` claim is
# at or after the resident's `keys_valid_since` column — no database row
# per session, no lookup by token string.
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
        iss: ISSUER
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

      issued_at = Time.zone.at(claims['iat'].to_f)
      return nil if issued_at < resident.keys_valid_since

      resident
    end

    private

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
      @secret ||= Rails.application.key_generator.generate_key('comeals-jwt-auth-v1', 32)
    end
  end
end
