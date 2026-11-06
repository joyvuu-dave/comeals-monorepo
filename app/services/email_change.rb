# typed: true
# frozen_string_literal: true

# A resident's change of their own email (ADR 0014). The new address is
# used only after the resident opens a one-use link sent to it. Until
# then it waits in residents.pending_email, and the old address still
# signs in. So a typo cannot lock anyone out: a link sent to a wrong
# address is never opened.
#
# The link's token is only in the email. The database keeps its SHA-256
# digest (residents.email_change_token_digest), for the same reasons as a
# password reset token (PasswordReset). A new request replaces the digest,
# so only the newest link works.
#
# The old address gets a notice when a change is asked for. Changing the
# email asks for no password (decided 2026-11-05), so the notice is what
# tells a person that someone else used a device they left signed in.
class EmailChange
  extend T::Sig

  LIFETIME = 24.hours

  # The answer for a token no resident has: a link already used, replaced
  # by a newer one, or cancelled.
  UNKNOWN = 'This email change link does not work. It may have been used already, ' \
            'or replaced by a newer one. Change your email again from your profile.'
  EXPIRED = 'This email change link has expired. Change your email again from your profile.'

  # Puts a change to new_email on the resident, unsaved, and returns the
  # token for the link. The caller saves the resident, and sends the
  # emails (send_emails) only once that save has committed.
  sig { params(resident: Resident, new_email: String).returns(String) }
  def self.start(resident, new_email)
    token = SecureRandom.urlsafe_base64(32)
    resident.pending_email = new_email
    resident.email_change_token_digest = digest(token)
    resident.email_change_sent_at = Time.current
    token
  end

  # Takes a change that is waiting off the resident, unsaved. Its link
  # stops working.
  sig { params(resident: Resident).void }
  def self.cancel(resident)
    resident.pending_email = nil
    resident.email_change_token_digest = nil
    resident.email_change_sent_at = nil
  end

  # The link to the new address, then the notice to the old one. Returns
  # :sent, or :mail_failed when the link did not go out. The change still
  # waits then, and the resident can ask for the link again from their
  # profile (send_link). A notice that did not go out is reported and
  # does not stop anything: the link went out, and the change still
  # needs it.
  #
  # old_email is nil when the resident had none. A resident signs in with
  # their email, but an admin can clear it afterwards.
  sig { params(resident: Resident, token: String, old_email: T.nilable(String)).returns(Symbol) }
  def self.send_emails(resident, token, old_email)
    return :mail_failed if send_link(resident, token) == :mail_failed
    return :sent if old_email.nil?

    begin
      ResidentMailer.email_change_notice_email(resident, old_email).deliver_now
    rescue *MAIL_DELIVERY_ERRORS => e
      MailDeliveryFailure.report(e, mailer: 'email_change_notice_email', recipient: old_email)
    end
    :sent
  end

  # The link alone, to the waiting address: :sent or :mail_failed.
  sig { params(resident: Resident, token: String).returns(Symbol) }
  def self.send_link(resident, token)
    ResidentMailer.email_change_link_email(resident, token).deliver_now
    :sent
  rescue *MAIL_DELIVERY_ERRORS => e
    MailDeliveryFailure.report(e, mailer: 'email_change_link_email', recipient: resident.pending_email)
    :mail_failed
  end

  # What opening a link did, and its message for the person.
  class Outcome < T::Struct
    const :changed, T::Boolean
    const :message, String
  end

  # Opens the link with this token: the waiting address becomes the
  # resident's email. Anything but a string (a request can send a number
  # or a list) is nobody's token.
  #
  # The address is checked again here, not only when it was asked for. In
  # between, an admin can give it to someone else, or another resident can
  # open their own link to it first. The model's checks say so, and the
  # unique index on lower(email) catches the two links opened at the same
  # moment. Either way the change can never work, so it is taken off.
  sig { params(token: T.untyped).returns(Outcome) }
  def self.confirm(token)
    resident = token.is_a?(String) ? Resident.find_by(email_change_token_digest: digest(token)) : nil
    return Outcome.new(changed: false, message: UNKNOWN) if resident.nil?

    sent_at = T.must(resident.email_change_sent_at)
    if sent_at < LIFETIME.ago
      cancel(resident)
      resident.save!(validate: false)
      return Outcome.new(changed: false, message: EXPIRED)
    end

    new_email = T.must(resident.pending_email)
    resident.email = new_email
    cancel(resident)
    return Outcome.new(changed: true, message: "Your email is now #{new_email}.") if save_new_email(resident)

    # Some other field on the row can be what is invalid, for example a
    # stored phone number that newer Phonelib data rejects (#105). Then
    # those reasons are the ones to show.
    reasons = resident.errors.full_messages_for(:email)
    reasons = resident.errors.full_messages if reasons.empty?
    reasons = ['Email has already been taken'] if reasons.empty?
    refused = Resident.find(T.must(resident.id))
    cancel(refused)
    refused.save!(validate: false)
    Outcome.new(changed: false,
                message: "Your email was not changed to #{new_email}:\n#{reasons.join("\n")}")
  end

  # Saves the new address, or returns false with the reason in errors.
  # A unique index refusal is the same answer as the model's own check:
  # someone took the address after that check ran.
  sig { params(resident: Resident).returns(T::Boolean) }
  def self.save_new_email(resident)
    Resident.transaction(requires_new: true) { resident.save }
  rescue ActiveRecord::RecordNotUnique
    false
  end
  private_class_method :save_new_email

  sig { params(token: String).returns(String) }
  def self.digest(token)
    Digest::SHA256.hexdigest(token)
  end
end
