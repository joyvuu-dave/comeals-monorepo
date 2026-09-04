# typed: true
# frozen_string_literal: true

# Issues a password reset link: stamps a fresh token on the resident and
# emails it. Shared by the resident-facing "forgot password" flow
# (Api::V1::ResidentsController#password_reset) and the admin "Send password
# reset email" button (app/admin/resident.rb).
#
# Returns one of three symbols the caller turns into a response:
#
#   :sent        — token saved and email delivered
#   :save_failed — the resident did not save; details in resident.errors
#   :mail_failed — token saved but the email did not go out, so the resident
#                  can retry, or an admin can send again later
class PasswordReset
  def self.request(resident)
    resident.reset_password_token = SecureRandom.urlsafe_base64
    resident.reset_password_sent_at = Time.current
    return :save_failed unless resident.save

    ResidentMailer.password_reset_email(resident).deliver_now
    :sent
  rescue *MAIL_DELIVERY_ERRORS => e
    MailDeliveryFailure.report(e, mailer: 'password_reset_email', recipient: resident.email)
    :mail_failed
  end
end
