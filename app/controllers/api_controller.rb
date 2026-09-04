# typed: true
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

  # Who the audited gem records as the author of a change (see
  # config/initializers/audited.rb). API changes are attributed to the
  # authenticated resident.
  def audited_user
    current_resident_api
  end

  # The API auth check. Each controller wires it with its own
  # before_action line — which actions are public (an iCal feed, a
  # password reset) is per-controller knowledge, but the check itself
  # lives once.
  def authenticate
    not_authenticated_api unless signed_in_resident_api?
  end

  def not_authenticated_api
    render json: { message: 'You are not authenticated. Please try signing in and then try again.' },
           status: :unauthorized and return
  end

  def not_found_api
    msg = "The page you were looking for doesn't exist. You may have " \
          'mistyped the address or the page may have moved.'
    render json: { message: msg },
           status: :not_found and return
  end

  private

  # The start/end wire shape the calendar modals send (the frontend's
  # buildStartEndPayload): one day split into parts, plus start and end
  # times. An all-day event starts at midnight and has no end. Returns
  # { start_date:, end_date: }, or nil when the parts do not name a
  # real date — the caller renders the 400.
  def parse_start_end_params(allday: false)
    year = params[:start_year].to_i
    month = params[:start_month].to_i
    day = params[:start_day].to_i

    if allday
      { start_date: Time.zone.local(year, month, day, 0, 0), end_date: nil }
    else
      { start_date: Time.zone.local(year, month, day, params[:start_hours].to_i, params[:start_minutes].to_i),
        end_date: Time.zone.local(year, month, day, params[:end_hours].to_i, params[:end_minutes].to_i) }
    end
  rescue StandardError
    nil
  end

  def render_invalid_date
    render json: { message: 'Error: Invalid date' }, status: :bad_request
  end

  # Resolve both @current_resident_api and @current_api_key in one pass.
  # JWT path is tried first (the post-migration default). If that fails we
  # fall back to a Key.find_by lookup so cookies issued before the JWT
  # deploy keep working. The retirement condition for the fallback is
  # written on the Key model.
  def resolve_current_session!
    token = bearer_token_from_header || params[:token].presence

    if (resident = JwtAuth.authenticate(token))
      @current_api_key = nil
      @current_resident_api = resident
      return
    end

    key = token ? Key.find_by(token: token) : nil
    @current_api_key = key
    @current_resident_api = key&.identity
  end

  # Extract a token from "Authorization: Bearer <token>". Returns nil for any
  # other scheme (Basic, no header, malformed) so we fall through to the
  # query-param fallback cleanly. Memoized because both resolve_current_session!
  # and set_community_timezone read it on every request.
  def bearer_token_from_header
    return @bearer_token_from_header if defined?(@bearer_token_from_header)

    header = request.headers['Authorization'].to_s
    match = header.match(/\ABearer\s+(?<token>\S+)\z/i)
    @bearer_token_from_header = match && match[:token]
  end

  def set_community_timezone(&)
    if bearer_token_from_header.present? || params[:token].present?
      tz = current_resident_api&.community&.timezone.presence
      return Time.use_zone(tz, &) if tz && ActiveSupport::TimeZone[tz]
    end
    yield
  end
end
