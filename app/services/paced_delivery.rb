# typed: true
# frozen_string_literal: true

# Sends many emails without tripping Gmail.
#
# In July 2026 the broadcast rake tasks stopped delivering: each
# deliver_now opened its own SMTP connection and logged in again, dozens
# of times in a few seconds, and Gmail throttled the account. This is the
# paced sender the broadcast_email initializer asked for. Every path that
# mails more than one person goes through it:
#
#   PacedDelivery.deliver(cooks, mailer: 'reconciliation_notify_email') do |cook|
#     ReconciliationMailer.reconciliation_notify_email(cook, reconciliation)
#   end
#   # => #<Result sent: 12, failed: 0, skipped: 0>
#
# Three rules, all here and nowhere else:
#   1. One SMTP session per run. The block builds each message; the
#      messages go out over a single logged-in connection.
#   2. A pause between messages (PAUSE seconds).
#   3. A cap per run (CAP messages). Items past the cap are counted as
#      skipped, not sent, and the caller decides what that means — the
#      notify tasks do not mark a rotation as notified unless every message
#      went out.
#
# A failed message is reported (MailDeliveryFailure) and counted; the run
# goes on to the next person. A failure to open the session counts every
# message as failed. Nothing here raises for a delivery problem: the
# callers have already committed the thing the mail is about, and a lost
# email is fixable.
#
# When the delivery method is not :smtp (test, letter_opener, staging) the
# messages go through deliver_now one by one with no pause, so specs and
# the dev inbox see exactly what production would send.
class PacedDelivery
  PAUSE = 1.5
  CAP = 100

  Result = Data.define(:sent, :failed, :skipped) do
    def complete? = failed.zero? && skipped.zero?
  end

  # Delivers the message the block builds for each item. `recipient` is
  # only for the failure log; it defaults to the item's email. `after_send`
  # runs once per delivered message, right after it went out — callers use
  # it to write the MailDelivery row that keeps a rerun from sending twice.
  def self.deliver(items, mailer:, recipient: ->(item) { item.email }, after_send: ->(_item) {}, &build)
    new(items, mailer: mailer, recipient: recipient, after_send: after_send, build: build).call
  end

  # Overridable in specs; sleeps in real runs.
  def self.pause
    sleep(PAUSE)
  end

  def initialize(items, mailer:, recipient:, after_send:, build:)
    @items = items.to_a
    @mailer = mailer
    @recipient = recipient
    @after_send = after_send
    @build = build
  end

  def call
    @sent = 0
    @failed = 0
    @skipped = 0

    with_session { |deliver| send_each(deliver) }

    Result.new(sent: @sent, failed: @failed, skipped: @skipped)
  end

  private

  def send_each(deliver)
    @items.each_with_index do |item, index|
      if index >= CAP
        @skipped += 1
        next
      end
      self.class.pause if index.positive? && smtp?

      begin
        deliver.call(@build.call(item))
        @sent += 1
        @after_send.call(item)
      rescue *MAIL_DELIVERY_ERRORS => e
        @failed += 1
        MailDeliveryFailure.report(e, mailer: @mailer, recipient: @recipient.call(item))
      end
    end
    log_cap if @skipped.positive?
  end

  def smtp?
    ActionMailer::Base.delivery_method == :smtp
  end

  # Yields a lambda that delivers one ActionMailer::MessageDelivery. Over
  # SMTP the lambda points the message at the open session; otherwise it
  # is plain deliver_now.
  def with_session
    return yield(->(message) { message.deliver_now }) unless smtp?

    open_smtp do |session|
      yield(lambda do |message|
        message.message.delivery_method(SessionDelivery, session: session)
        message.deliver_now
      end)
    end
  rescue *MAIL_DELIVERY_ERRORS => e
    # The session itself could not be opened: nothing was sent.
    @failed = @items.size - @sent - @skipped
    MailDeliveryFailure.report(e, mailer: @mailer)
  end

  def open_smtp(&)
    settings = ActionMailer::Base.smtp_settings
    smtp = Net::SMTP.new(settings[:address], settings[:port])
    smtp.enable_starttls_auto if settings[:enable_starttls_auto]
    smtp.open_timeout = settings[:open_timeout] if settings[:open_timeout]
    smtp.read_timeout = settings[:read_timeout] if settings[:read_timeout]
    smtp.start(settings[:domain], settings[:user_name], settings[:password], settings[:authentication]&.to_sym, &)
  end

  def log_cap
    Rails.logger.error("#{@mailer}: per-run cap of #{CAP} reached, #{@skipped} not sent")
  end

  # A Mail delivery method that writes to an SMTP session someone else
  # opened, so many messages share one login. Mail instantiates it with
  # the settings hash given to Mail::Message#delivery_method.
  class SessionDelivery
    def initialize(settings)
      @session = settings.fetch(:session)
    end

    def deliver!(mail)
      @session.send_message(mail.encoded, mail.smtp_envelope_from, mail.smtp_envelope_to)
    end
  end
end
