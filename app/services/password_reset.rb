# typed: true
# frozen_string_literal: true

# Issues a password reset link and finds the resident a link belongs to.
# Shared by the resident-facing "forgot password" flow
# (Api::V1::ResidentsController#password_reset) and the admin "Send password
# reset email" button (app/admin/resident.rb).
#
# The token is only in the email. The database keeps its SHA-256 digest
# (residents.reset_password_token_digest), so whoever reads the table, a
# backup, or a copy of production cannot use a live link. A digest with no
# salt and no slow hash is the standard for this: the token is 32 random
# bytes, so there is nothing to guess, unlike a password a person chose.
# The lookup compares digests, never tokens. How long it takes can depend
# on how the digest of what was sent compares with the digests in the
# table, and knowing that does not help anyone: to use it they would need
# a token with a given digest, which SHA-256 does not allow.
#
# request returns one of three symbols the caller turns into a response:
#
#   :sent        — digest saved and email delivered
#   :save_failed — the resident did not save; details in resident.errors
#   :mail_failed — digest saved but the email did not go out, so the
#                  resident can retry, or an admin can send again later
class PasswordReset
  def self.request(resident)
    token = SecureRandom.urlsafe_base64(32)
    resident.reset_password_token_digest = digest(token)
    resident.reset_password_sent_at = Time.current
    return :save_failed unless resident.save

    ResidentMailer.password_reset_email(resident, token).deliver_now
    :sent
  rescue *MAIL_DELIVERY_ERRORS => e
    MailDeliveryFailure.report(e, mailer: 'password_reset_email', recipient: resident.email)
    :mail_failed
  end

  # The resident whose reset link carries this token, or nil. Anything but
  # a string (a request can send a number or a list) is nobody's.
  def self.resident_for(token)
    return nil unless token.is_a?(String)

    Resident.find_by(reset_password_token_digest: digest(token))
  end

  def self.digest(token)
    Digest::SHA256.hexdigest(token)
  end
end
