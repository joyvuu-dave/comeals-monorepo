# typed: true
# frozen_string_literal: true

module Api
  module V1
    class ResidentsController < ApiController
      RESET_TOKEN_LIFETIME = 24.hours

      before_action :authenticate, only: [:show_id]

      # GET /api/v1/residents/id
      def show_id
        render json: current_resident_api.id
      end

      # GET /api/v1/residents/name/:token
      def show_name
        resident = Resident.find_by(reset_password_token: params[:token])

        if resident.nil?
          return render json: { message: 'Password reset link is incorrect or expired.' }, status: :bad_request
        end

        sent_at = resident.reset_password_sent_at
        if sent_at.nil? || sent_at < RESET_TOKEN_LIFETIME.ago
          render json: { message: 'Password reset link has expired. Please request a new one.' },
                 status: :bad_request and return
        end

        render json: { name: ResidentNameShortener.short(resident.name) }
      end

      # POST /api/v1/residents/token { email: 'email', password: 'password' }
      # Auth flow with multiple early-exit checks
      def token
        # Kids aren't required to have email addresses;
        # this prevents those accounts from signing in
        render json: { message: 'Email required.' }, status: :bad_request and return if params[:email].blank?

        resident = Resident.find_by(email: params[:email]&.strip&.downcase)
        if resident.nil?
          return render json: { message: "No resident with email #{params[:email]}" }, status: :bad_request
        end

        if resident.authenticate(params[:password])
          community = T.must(resident.community)
          render json: { token: JwtAuth.encode(resident),
                         community_id: community.id,
                         resident_id: resident.id, username: ResidentNameShortener.short(resident.name),
                         timezone: community.timezone }
        else
          render json: { message: 'Incorrect password' }, status: :bad_request
        end
      end

      # --multi-step auth flow with email delivery
      # POST /api/v1/residents/password-reset { email: 'email' }
      def password_reset
        render json: { message: 'Email required.' }, status: :bad_request and return if params[:email].blank?

        resident = Resident.find_by(email: params[:email]&.strip&.downcase)

        return render json: { message: 'No resident with that email address.' }, status: :bad_request if resident.nil?

        case PasswordReset.request(resident)
        when :sent
          render json: { message: 'Check your email.' }
        when :mail_failed
          render json: {
                   message: 'Password reset saved but email could not be sent. Please contact an administrator.'
                 },
                 status: :service_unavailable
        else
          render json: { message: 'Error. Please try again.' }, status: :bad_request
        end
      end

      # POST /api/v1/residents/password-reset/:token { password: 'password' }
      def password_new
        resident = Resident.find_by(reset_password_token: params[:token])

        return render json: { message: 'Error.' }, status: :bad_request if resident.nil?

        sent_at = resident.reset_password_sent_at
        if sent_at.nil? || sent_at < RESET_TOKEN_LIFETIME.ago
          resident.update_columns(reset_password_token: nil, reset_password_sent_at: nil)
          render json: { message: 'Password reset link has expired. Please request a new one.' },
                 status: :bad_request and return
        end

        # A blank password is allowed, on purpose. The community asked for
        # it: the app runs on a shared screen with no secrets on it, and some
        # residents want to log in with only their email. So '' is a valid
        # new password here, and the login accepts it (Resident#password=).
        # Pinned by spec/requests/api/v1/residents_controller_spec.rb.
        resident.reset_password_token = nil
        resident.reset_password_sent_at = nil
        resident.password = params[:password].to_s

        render json: { message: 'Password updated!' } and return if resident.save

        render json: { message: 'Invalid password.' }, status: :bad_request
      end

      # GET api/v1/residents/:id/ical
      def ical
        resident = Resident.find(params[:id]) # rubocop:disable Rails/StrongParametersExpect --routed :id is read directly, matching this codebase's bare params[] convention
        community = T.must(resident.community)
        feed = MealIcalFeed.new(community, calendar_name: "My #{community.name}")

        # Precompute cook dates to avoid a query per meal_resident in the loop below
        cook_dates = Bill.joins(:meal)
                         .where(resident_id: resident.id)
                         .pluck('meals.date').to_set

        Bill.where(resident_id: resident.id).includes(:meal).find_each do |bill|
          meal = T.must(bill.meal)
          feed.add_meal(meal,
                        summary: 'Cook Common Dinner',
                        description: "#{meal.description}\n\n\n\nView here: #{root_url}/meals/#{meal.id}/edit")
        end

        # A day they cook already has its Cook event; skip the Attend one.
        MealResident.where(resident_id: resident.id).includes(:meal).find_each do |mr|
          meal = T.must(mr.meal)
          next if cook_dates.include?(meal.date)

          feed.add_meal(meal,
                        summary: 'Attend Common Dinner',
                        description: "#{meal.description}\n\n\n\nView here: #{root_url}/meals/#{meal.id}/edit")
        end

        render plain: feed.to_ical, content_type: 'text/calendar'
      end
    end
  end
end
