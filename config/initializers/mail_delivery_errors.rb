# typed: false
# frozen_string_literal: true

require 'net/smtp'

# Exceptions that indicate an email delivery infrastructure failure
# (network, DNS, SMTP) rather than a bug in application code.
# Used across controllers, models, and rake tasks to rescue delivery
# errors without accidentally swallowing programming errors like
# NoMethodError. In its own file so `rescue *MAIL_DELIVERY_ERRORS`
# call sites lead somewhere findable — it used to hide inside the
# mail interceptor's initializer (#51).
MAIL_DELIVERY_ERRORS = [
  SocketError, IOError,
  Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::ETIMEDOUT,
  Net::SMTPAuthenticationError, Net::SMTPServerBusy, Net::SMTPSyntaxError,
  Net::SMTPFatalError, Net::SMTPUnknownError, Net::ReadTimeout, Net::OpenTimeout
].freeze
