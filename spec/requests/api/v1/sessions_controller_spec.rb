# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Sessions API' do
  let(:community) { create(:community, slug: 'testcom') }
  let(:unit) { create(:unit, community: community) }
  let!(:resident) do
    create(:resident, community: community, unit: unit, email: 'alice@example.com',
                      password: 'correctpassword')
  end

  # Legacy Key (created by the factory after(:create) hook) — represents a
  # session issued before the JWT migration.
  let(:legacy_key) { resident.keys.first }

  def legacy_auth(key) = { 'Authorization' => "Bearer #{key.token}" }
  def jwt_auth(res)    = { 'Authorization' => "Bearer #{JwtAuth.encode(res)}" }

  describe 'DELETE /api/v1/sessions/current' do
    context 'with a legacy Key session' do
      it 'destroys the key row' do
        legacy_key
        other_key = resident.keys.create!

        expect { delete '/api/v1/sessions/current', headers: legacy_auth(legacy_key) }
          .to change(Key, :count).by(-1)

        expect(response).to have_http_status(:ok)
        expect(Key.exists?(legacy_key.id)).to be(false)
        expect(Key.exists?(other_key.id)).to be(true)
      end
    end

    context 'with a JWT session' do
      it 'succeeds without touching the keys table (no server-side state exists)' do
        expect { delete '/api/v1/sessions/current', headers: jwt_auth(resident) }
          .not_to change(Key, :count)

        expect(response).to have_http_status(:ok)
        expect(response.parsed_body['message']).to eq('Signed out.')
      end
    end

    it 'returns 401 without a token' do
      delete '/api/v1/sessions/current'
      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe 'Authentication paths' do
    it 'authenticates a freshly-issued JWT' do
      get '/api/v1/residents/id', headers: jwt_auth(resident)
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq(resident.id)
    end

    it 'authenticates a legacy Key via Bearer header (grandfather clause)' do
      get '/api/v1/residents/id', headers: legacy_auth(legacy_key)
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq(resident.id)
    end

    it 'still accepts a legacy Key passed as a query parameter' do
      get '/api/v1/residents/id', params: { token: legacy_key.token }
      expect(response).to have_http_status(:ok)
    end

    it "rejects a JWT whose iat predates the resident's keys_valid_since" do
      token = JwtAuth.encode(resident)
      resident.update_column(:keys_valid_since, 1.hour.from_now)

      get '/api/v1/residents/id', headers: { 'Authorization' => "Bearer #{token}" }
      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe 'POST /api/v1/residents/token (login)' do
    it 'returns a JWT that authenticates as this resident' do
      post '/api/v1/residents/token', params: {
        email: 'alice@example.com',
        password: 'correctpassword'
      }

      expect(response).to have_http_status(:ok)
      jwt = response.parsed_body['token']
      expect(JwtAuth.authenticate(jwt)).to eq(resident)
    end

    it 'does not create a Key row (JWTs are stateless)' do
      expect do
        post '/api/v1/residents/token', params: {
          email: 'alice@example.com',
          password: 'correctpassword'
        }
      end.not_to change(Key, :count)
    end
  end

  # ---------------------------------------------------------------------------
  # Authorization header parsing — the exact production risk surface if the
  # parsing regex is ever relaxed or tightened. Locks in the accepted/rejected
  # shapes so regressions fail loudly.
  # ---------------------------------------------------------------------------
  describe 'Authorization header parsing' do
    it 'accepts lowercase "bearer" (scheme is case-insensitive per RFC 7235)' do
      jwt = JwtAuth.encode(resident)

      get '/api/v1/residents/id', headers: { 'Authorization' => "bearer #{jwt}" }

      expect(response).to have_http_status(:ok)
    end

    it 'tolerates multiple whitespace characters between scheme and token' do
      jwt = JwtAuth.encode(resident)

      get '/api/v1/residents/id', headers: { 'Authorization' => "Bearer   #{jwt}" }

      expect(response).to have_http_status(:ok)
    end

    it 'rejects a Basic auth header even if the credentials encode a valid token' do
      # The regex requires the scheme to be "Bearer". Any other scheme must
      # fall through to the query-param fallback (which is also absent here).
      get '/api/v1/residents/id', headers: { 'Authorization' => "Basic #{legacy_key.token}" }

      expect(response).to have_http_status(:unauthorized)
    end

    it 'rejects an empty Bearer value (no token present)' do
      get '/api/v1/residents/id', headers: { 'Authorization' => 'Bearer ' }

      expect(response).to have_http_status(:unauthorized)
    end

    it 'does not crash on a completely malformed Authorization header' do
      get '/api/v1/residents/id', headers: { 'Authorization' => '!!!garbage!!!' }

      expect(response).to have_http_status(:unauthorized)
    end

    it 'prefers the Bearer header over a conflicting ?token= query param' do
      # When both are present, the header wins. This matters during the
      # transition: a browser with a legacy ?token= pattern somewhere AND a
      # new Bearer interceptor installed should always use the header.
      other_resident = create(:resident, community: community, unit: unit)
      jwt_for_other = JwtAuth.encode(other_resident)

      get '/api/v1/residents/id',
          params: { token: legacy_key.token },
          headers: { 'Authorization' => "Bearer #{jwt_for_other}" }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq(other_resident.id)
    end

    it 'falls back to the query param when the Bearer header is malformed' do
      get '/api/v1/residents/id',
          params: { token: legacy_key.token },
          headers: { 'Authorization' => 'Bearer ' }

      expect(response).to have_http_status(:ok)
    end
  end

  # ---------------------------------------------------------------------------
  # The deploy-day transition: user has a legacy Key cookie, authenticates via
  # the fallback path, logs out (Key row destroyed), logs back in (JWT issued),
  # continues with the JWT. This is the path every existing user takes on the
  # first session after the JWT rollout deploys.
  # ---------------------------------------------------------------------------
  describe 'legacy Key → JWT transition' do
    it 'works end-to-end for a pre-deploy session' do
      # 1. Browser arrives with a legacy Key cookie (opaque token).
      #    First request hits the Key.find_by fallback path.
      legacy_token = legacy_key.token
      get '/api/v1/residents/id', headers: { 'Authorization' => "Bearer #{legacy_token}" }
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq(resident.id)

      # 2. User clicks logout. The server destroys the Key row.
      expect do
        delete '/api/v1/sessions/current',
               headers: { 'Authorization' => "Bearer #{legacy_token}" }
      end.to change(Key, :count).by(-1)
      expect(response).to have_http_status(:ok)

      # 3. The legacy token is now dead — no more fallback.
      get '/api/v1/residents/id', headers: { 'Authorization' => "Bearer #{legacy_token}" }
      expect(response).to have_http_status(:unauthorized)

      # 4. User logs in. Response is a JWT. No new Key row created.
      expect do
        post '/api/v1/residents/token',
             params: { email: 'alice@example.com', password: 'correctpassword' }
      end.not_to change(Key, :count)
      expect(response).to have_http_status(:ok)
      jwt = response.parsed_body['token']

      # 5. JWT authenticates on subsequent requests.
      get '/api/v1/residents/id', headers: { 'Authorization' => "Bearer #{jwt}" }
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq(resident.id)
    end

    it 'leaves the legacy Key intact if the user logs in without logging out first' do
      # Some users will just re-log-in without explicitly logging out (the
      # frontend overwrites the token cookie). The old Key row is orphaned —
      # harmless, but assert it's still present so we'd notice if a future
      # change silently started destroying it.
      legacy_token = legacy_key.token
      original_keys = resident.keys.pluck(:id)

      post '/api/v1/residents/token',
           params: { email: 'alice@example.com', password: 'correctpassword' }
      expect(response).to have_http_status(:ok)

      expect(resident.reload.keys.pluck(:id)).to eq(original_keys)
      # And the orphan still authenticates until something else invalidates it
      # (password change, explicit logout, or admin revocation).
      get '/api/v1/residents/id', headers: { 'Authorization' => "Bearer #{legacy_token}" }
      expect(response).to have_http_status(:ok)
    end

    it 'invalidates BOTH a legacy Key cookie AND a simultaneously-issued JWT on password change' do
      # Real-world shape: user has laptop (legacy Key) and phone (fresh JWT).
      # Password change on the web has to kill both.
      legacy_token = legacy_key.token
      jwt = JwtAuth.encode(resident)

      # Both paths work before the change
      get '/api/v1/residents/id', headers: { 'Authorization' => "Bearer #{legacy_token}" }
      expect(response).to have_http_status(:ok)
      get '/api/v1/residents/id', headers: { 'Authorization' => "Bearer #{jwt}" }
      expect(response).to have_http_status(:ok)

      # Change password (triggers revoke_all_sessions_if_password_changed).
      # Tiny sleep because keys_valid_since is written via update_column at
      # microsecond precision; same-tick changes can land identically on some
      # systems and trip the inclusive equality path.
      sleep 0.01
      resident.update!(password: 'newsecret')

      # Both paths now dead
      get '/api/v1/residents/id', headers: { 'Authorization' => "Bearer #{legacy_token}" }
      expect(response).to have_http_status(:unauthorized)
      get '/api/v1/residents/id', headers: { 'Authorization' => "Bearer #{jwt}" }
      expect(response).to have_http_status(:unauthorized)
    end
  end

  # ---------------------------------------------------------------------------
  # Double-destroy and wrong-owner edge cases — defensive rather than
  # scenario-driven, since these states shouldn't occur in normal flow.
  # ---------------------------------------------------------------------------
  describe 'DELETE /api/v1/sessions/current edge cases' do
    it 'returns 401 on the second destroy of the same token (idempotence via auth failure)' do
      delete '/api/v1/sessions/current', headers: legacy_auth(legacy_key)
      expect(response).to have_http_status(:ok)

      delete '/api/v1/sessions/current', headers: legacy_auth(legacy_key)
      expect(response).to have_http_status(:unauthorized)
    end

    it 'does not destroy sibling Key rows belonging to other devices' do
      laptop_key = legacy_key
      phone_key = resident.keys.create!

      delete '/api/v1/sessions/current', headers: legacy_auth(laptop_key)

      expect(response).to have_http_status(:ok)
      expect(Key.exists?(laptop_key.id)).to be(false)
      expect(Key.exists?(phone_key.id)).to be(true)
    end
  end
end
