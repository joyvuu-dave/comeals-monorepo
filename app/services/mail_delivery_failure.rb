# frozen_string_literal: true

# One place for a caught mail delivery error to go. Every rescue of
# MAIL_DELIVERY_ERRORS should call this instead of logging on its own.
#
# It writes to two places, because each answers a different question:
#
#   Rails.logger.error — what happened, next to the request or task log.
#   Rails.error.report — a Bugsnag alert (via BugsnagErrorSubscriber), so a
#                        failure the rescue swallowed still emails someone.
#
# Before this existed, a rescued mail failure only wrote a log line, so
# nothing alerted anyone. On 2026-08-17 Gmail revoked the app's SMTP
# password, every outgoing email failed, and the first report was a user's
# screenshot of the password-reset error message.
#
# The recipient's address goes only into the log line, never into the
# Bugsnag context — the log already holds addresses, but Bugsnag is a third
# party and the mailer name is enough to debug with.
class MailDeliveryFailure
  def self.report(error, mailer:, recipient: nil)
    target = recipient ? " for #{recipient}" : ''
    Rails.logger.error("#{mailer} failed#{target}: #{error.class} - #{error.message}")
    Rails.error.report(error, handled: true, severity: :error, source: 'mailer', context: { mailer: mailer })
  end
end
