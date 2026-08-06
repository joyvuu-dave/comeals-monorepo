# frozen_string_literal: true

# Intercepts all outgoing emails and redirects them to a single address.
# Activate by setting MAIL_INTERCEPT_TO in your environment:
#
#   MAIL_INTERCEPT_TO=dpriddle@gmail.com rails s
#
# The original recipient is prepended to the subject line so you can
# see who each email would have been delivered to.
#
# Blocked in production as a safety guardrail.
class MailInterceptor
  def self.delivering_email(message)
    original_to = Array(message.to).join(', ')
    message.subject = "[To: #{original_to}] #{message.subject}"
    message.to = ENV.fetch('MAIL_INTERCEPT_TO', nil)
    message.cc = nil
    message.bcc = nil
  end
end

if ENV['MAIL_INTERCEPT_TO'].present?
  if Rails.env.production?
    Rails.logger.warn('MAIL_INTERCEPT_TO is set in production — ignoring. Remove this env var.')
  else
    ActionMailer::Base.register_interceptor(MailInterceptor)
  end
end
