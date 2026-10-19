# typed: false
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

  # Called once at boot, below. A method, so a spec can call it as
  # production would (spec/mailers/mail_interceptor_spec.rb).
  def self.install(mailer, env:, intercept_to:, logger:)
    return if intercept_to.blank?

    if env.production?
      logger.warn('MAIL_INTERCEPT_TO is set in production — ignoring. Remove this env var.')
    else
      mailer.register_interceptor(self)
    end
  end
end

MailInterceptor.install(ActionMailer::Base, env: Rails.env, intercept_to: ENV.fetch('MAIL_INTERCEPT_TO', nil),
                                            logger: Rails.logger)
