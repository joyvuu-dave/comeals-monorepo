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

  # Who a token can sign in: a resident, or the shared screen in the
  # Common House (CommonHouseLogin, which is not a resident). A caller of
  # authenticate gets one of the two and must say what each may do;
  # Sorbet refuses a call that only a Resident has.
  Login = T.type_alias { T.any(Resident, CommonHouseLogin) }

  class << self
    extend T::Sig

    # Sign and return a JWT string for the given login. The token names
    # the login by resident_id or by common_house_login_id, never both.
    # `iat` keeps its fraction of a second (RFC 7519 allows it).
    sig { params(login: Login).returns(String) }
    def encode(login)
      id_claim = case login
                 when Resident then :resident_id
                 when CommonHouseLogin then :common_house_login_id
                 else T.absurd(login)
                 end
      payload = {
        id_claim => login.id,
        iat: Time.current.to_f,
        iss: ISSUER,
        keys_valid_since: microseconds(T.must(login.keys_valid_since))
      }
      JWT.encode(payload, secret, ALGORITHM)
    end

    # Verify `token` and return the login it names, or nil for any failure
    # (bad signature, wrong issuer, revoked by keys_valid_since, no such
    # login, a token that names two logins or none, malformed input).
    sig { params(token: T.nilable(String)).returns(T.nilable(Login)) }
    def authenticate(token)
      return nil if token.blank?

      claims = decode(token)
      return nil unless claims

      login = find_login(claims)
      return nil unless login

      return nil unless still_valid?(claims, login)

      login
    end

    private

    # The login the token names. A token that names both kinds is refused:
    # encode never makes one, so it was not made by this code.
    sig { params(claims: T::Hash[String, T.untyped]).returns(T.nilable(Login)) }
    def find_login(claims)
      resident_id = claims['resident_id']
      common_house_login_id = claims['common_house_login_id']
      return nil if resident_id && common_house_login_id

      if resident_id
        Resident.find_by(id: resident_id)
      elsif common_house_login_id
        CommonHouseLogin.find_by(id: common_house_login_id)
      end
    end

    # A token with a keys_valid_since claim is good only while the column
    # still has that value. A resident's token without it (made before
    # #265) keeps the old rule: made at or after keys_valid_since. Every
    # Common House token was made after #265, so it must have the claim.
    sig { params(claims: T::Hash[String, T.untyped], login: Login).returns(T::Boolean) }
    def still_valid?(claims, login)
      keys_valid_since = T.must(login.keys_valid_since)
      made_with = claims['keys_valid_since']
      return made_with == microseconds(keys_valid_since) unless made_with.nil?

      login.is_a?(Resident) && Time.zone.at(claims['iat'].to_f) >= keys_valid_since
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
