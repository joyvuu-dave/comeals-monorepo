# frozen_string_literal: true

class ApiController < ActionController::API
  around_action :set_community_timezone

  def root_url
    @root_url ||= Rails.env.production? ? 'https://comeals.com' : 'http://localhost:3036'
  end

  # Non-nil only for legacy Key-backed sessions. JWT sessions have no
  # server-stored row, so this returns nil even when the caller is
  # authenticated. Use current_resident_api as the canonical check.
  def current_api_key
    return @current_api_key if defined?(@current_api_key)

    resolve_current_session!
    @current_api_key
  end

  def current_resident_api
    return @current_resident_api if defined?(@current_resident_api)

    resolve_current_session!
    @current_resident_api
  end

  def signed_in_resident_api?
    current_resident_api.present?
  end

  def not_authenticated_api
    render json: { message: 'You are not authenticated. Please try signing in and then try again.' },
           status: :unauthorized and return
  end

  def not_authorized_api
    msg = 'You are not authorized to view the page. You may have mistyped ' \
          'the address or might be signed into the wrong account.'
    render json: { message: msg },
           status: :forbidden and return
  end

  def not_found_api
    msg = "The page you were looking for doesn't exist. You may have " \
          'mistyped the address or the page may have moved.'
    render json: { message: msg },
           status: :not_found and return
  end

  private

  # Resolve both @current_resident_api and @current_api_key in one pass.
  # JWT path is tried first (the post-migration default). If that fails we
  # fall back to a Key.find_by lookup so cookies issued before the JWT
  # deploy keep working — see ADR / auth discussion.
  def resolve_current_session!
    token = bearer_token_from_header || params[:token].presence

    if (resident = JwtAuth.authenticate(token))
      @current_api_key = nil
      @current_resident_api = resident
      return
    end

    key = token && Key.find_by(token: token)
    @current_api_key = key
    @current_resident_api = key&.identity
  end

  # Extract a token from "Authorization: Bearer <token>". Returns nil for any
  # other scheme (Basic, no header, malformed) so we fall through to the
  # query-param fallback cleanly.
  def bearer_token_from_header
    header = request.headers['Authorization'].to_s
    match = header.match(/\ABearer\s+(?<token>\S+)\z/i)
    match && match[:token]
  end

  def set_community_timezone(&)
    if bearer_token_from_header.present? || params[:token].present?
      tz = current_resident_api&.community&.timezone.presence
      return Time.use_zone(tz, &) if tz && ActiveSupport::TimeZone[tz]
    end
    yield
  end
end
