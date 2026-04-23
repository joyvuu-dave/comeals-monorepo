# frozen_string_literal: true

module Api
  module V1
    # Session (API key) management. Each Key is an active login.
    #
    # Only "log out this device" is exposed. Broader revocation is achieved
    # by changing the password — which destroys every session except the
    # caller's (see Resident#revoke_all_sessions_if_password_changed).
    class SessionsController < ApiController
      before_action :authenticate

      # DELETE /api/v1/sessions/current
      #
      # Legacy Key sessions: destroy the server-side row so the token is
      # actually invalidated.
      #
      # JWT sessions: there is no server-side state to remove — the token
      # itself is self-validating. The client is expected to clear its
      # cookie; the JWT remains cryptographically valid if copied elsewhere.
      # That's the documented trade-off of stateless auth.
      def destroy_current
        current_api_key&.destroy!
        render json: { message: 'Signed out.' }
      end

      private

      def authenticate
        not_authenticated_api unless signed_in_resident_api?
      end
    end
  end
end
