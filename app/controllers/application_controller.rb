# frozen_string_literal: true

class ApplicationController < ActionController::Base
  skip_before_action :verify_authenticity_token, if: :read_only_admin_token?

  # Publish the token flag for SuperuserAdapter, which cannot see the request.
  # This runs before every action, including ActiveAdmin's, so the adapter
  # never has to guess. Setting it to the boolean (not the token) keeps the
  # secret out of anything that dumps Current.
  before_action :expose_read_only_admin_token
  # Every wall-clock time is read in the community's zone (CLAUDE.md). The
  # API has its own wrapper (ApiController#set_community_timezone); this
  # one covers admin, where a typed time is parsed and a stored time is
  # shown in Time.zone. Without it both used the app's fixed zone
  # (time hunt, 2026-08-26). Before the first Community row exists there
  # is no zone to use, and the app zone is the only one there is.
  around_action :use_community_timezone

  # A POST whose CSRF token does not match its session. Two senders: a bot
  # posting a canned body at admin.comeals.com, and an admin who left the
  # login tab open until the session cookie expired. Rails' default renders
  # a 422 error page and reports to Bugsnag (8 bot reports, 2026-08-22 to
  # 24). Sending both to the login page with a message is right for the
  # admin and harmless for the bot. The API is ActionController::API and
  # does not inherit this.
  rescue_from ActionController::InvalidAuthenticityToken, with: :csrf_failed

  # GET /admin-logout (admin)
  def admin_logout
    cookies.delete(:remember_admin_user_token)
    reset_session
    redirect_to '/'
  end

  def use_community_timezone(&)
    zone = ActiveSupport::TimeZone[Community.first&.timezone.to_s]
    return yield if zone.nil?

    Time.use_zone(zone, &)
  end

  def csrf_failed
    reset_session
    redirect_to '/login', alert: 'Your session expired. Please try again.'
  end

  def access_denied(_exception)
    redirect_to '/401'
  end

  # Allow read-only admin access via a shared token (used in reconciliation
  # email links so cooks can view their bills without an admin account).
  # When the token matches, we skip Devise authentication and return a
  # designated read-only admin user instead.
  def authenticate_admin_user_custom!
    return if read_only_admin_token?

    authenticate_admin_user!
  end

  def current_admin_user_custom
    return AdminUser.find(ENV.fetch('READ_ONLY_ADMIN_ID', nil)) if read_only_admin_token?

    current_admin_user
  end

  # Who the audited gem records as the author of a change (see
  # config/initializers/audited.rb). ActiveAdmin controllers inherit from
  # here, so admin edits are attributed to the signed-in admin.
  def audited_user
    current_admin_user_custom
  end

  private

  def expose_read_only_admin_token
    Current.read_only_admin_token = read_only_admin_token?
  end

  def read_only_admin_token?
    params[:token].present? && params[:token] == ENV['READ_ONLY_ADMIN_TOKEN']
  end
end
