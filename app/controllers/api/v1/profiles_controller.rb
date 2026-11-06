# typed: true
# frozen_string_literal: true

module Api
  module V1
    # A resident's own profile (ADR 0014): their name, vegetarian setting
    # and email, and the children in their unit who have no email. Only a
    # resident has a profile, so the Common House screen gets 403, the
    # same as for settling.
    class ProfilesController < ApiController
      NOTHING_WAITING = 'Your email has no change waiting. Change it from your profile.'

      before_action :authenticate, except: [:confirm_email]
      before_action :note_live_update_sender, only: [:update]

      # GET /api/v1/profile
      def show
        resident = current_resident_api
        return not_a_resident_api if resident.nil?

        render json: ProfileUpdate.profile(resident)
      end

      # PATCH /api/v1/profile { name, vegetarian, email, children: [{ id, name, vegetarian }] }
      def update
        resident = current_resident_api
        return not_a_resident_api if resident.nil?

        fields = ProfileUpdate.read(params)
        return render json: { message: fields }, status: :bad_request if fields.is_a?(String)

        outcome = RetryOnConflict.call { ProfileUpdate.save(T.must(resident.id), fields) }
        return render json: { message: outcome }, status: :bad_request if outcome.is_a?(String)

        render_saved(outcome)
      end

      # POST /api/v1/profile/email-link
      #
      # Sends the link for the waiting change of email again, as a new
      # link: the one sent before stops working. For a link that did not
      # arrive, or that expired. The old address gets no second notice.
      def email_link
        resident = current_resident_api
        return not_a_resident_api if resident.nil?

        restarted = RetryOnConflict.call { Resident.transaction { restart_email_change(T.must(resident.id)) } }
        return render json: { message: NOTHING_WAITING }, status: :bad_request if restarted.nil?

        waiting, token = restarted
        if EmailChange.send_link(waiting, token) == :sent
          return render json: { message: "We sent a new link to #{waiting.pending_email}." }
        end

        render json: { message: "The email to #{waiting.pending_email} could not be sent. " \
                                'Try again later, or ask an admin.' },
               status: :service_unavailable
      end

      # POST /api/v1/profile/email-confirm { email_token }
      #
      # The link in the email to the new address opens the app at
      # /confirm-email#token=..., and the page posts the token here. Like a
      # reset token, it never travels in a path, where Rails and Heroku's
      # router would log it (ResidentsController). No sign-in is needed:
      # the token shows the person reads the new address.
      def confirm_email
        outcome = RetryOnConflict.call { Resident.transaction { EmailChange.confirm(params[:email_token]) } }
        render json: { message: outcome.message }, status: outcome.changed ? :ok : :bad_request
      end

      private

      # The resident with a new link for their waiting change, and the
      # link's token, or nil when no change waits.
      def restart_email_change(resident_id)
        resident = Resident.find(resident_id)
        pending = resident.pending_email
        return nil if pending.nil?

        token = EmailChange.start(resident, pending)
        # Only the three email change columns changed, and none of them
        # can make the row invalid. Another field that is invalid (a phone
        # number newer Phonelib data rejects, #105) must not stop a link.
        resident.save!(validate: false)
        [resident, token]
      end

      # The save committed. When it started a change of email, the emails
      # go out now, and the answer says where to look.
      def render_saved(saved)
        token = saved.email_token
        return render json: { message: 'Your profile has been saved.', profile: saved.profile } if token.nil?

        pending = saved.resident.pending_email
        old_email = saved.old_email
        if EmailChange.send_emails(saved.resident, token, old_email) == :sent
          until_then = old_email.nil? ? '' : " Until then, sign in with #{old_email}."
          return render json: { message: 'Your profile has been saved. To change your email, open the link ' \
                                         "we sent to #{pending}.#{until_then}",
                                profile: saved.profile }
        end

        render json: { message: "Your profile has been saved, but the email to #{pending} could not be sent. " \
                                'Use "Send the link again" on your profile, or ask an admin.',
                       profile: saved.profile },
               status: :service_unavailable
      end
    end
  end
end
