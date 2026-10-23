# frozen_string_literal: true

# Gives a resident a live password reset link the way PasswordReset does,
# without sending an email, and returns the token. The database keeps only
# its digest, so a spec that needs the token gets it from here.
module ResetToken
  def give_reset_token(resident, token: SecureRandom.urlsafe_base64(32), sent_at: Time.current)
    resident.update_columns(reset_password_token_digest: PasswordReset.digest(token), reset_password_sent_at: sent_at)
    token
  end
end

RSpec.configure { |config| config.include ResetToken }
