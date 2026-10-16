# typed: true
# frozen_string_literal: true

# Make sure every recent settlement's mail went out: the cook mail to
# every cook, and the common house mail (ADR 0011 rule 9).
#
# NotifyCooksJob and CommonHouseMailJob send them after a settlement, and
# try a failed send again a few times within the first hours. A mail can
# still be missed: the mail server is down for longer than that, the job
# is lost (a worker that dies before it runs), or the settlement is not
# the latest one, which is all the rake tasks reach. So each night this
# job compares what should be true (every cook with an email address has
# a MailDelivery row, and so has the common house mail) with what is, and
# queues the job again for each settlement that still owes a mail. Each
# job sends only what has not gone out, so nobody gets it twice.
#
# Only settlements from the last WINDOW are tried. A settlement that
# leaves the window with a mail still not sent is reported to Bugsnag,
# once, by the first run after it left, with the line to run to send it.
#
# And only settlements made since this job first ran. MailDelivery rows
# for these mails started with the jobs that send them, so an older
# settlement has none even when every cook got the mail. Without this
# floor the first night after the deploy would mail every cook of the
# settlements from the week before a second time, and mail the common
# house about them for the first time.
class SendMissedSettlementMailJob < RecurringJob
  HEALTHCHECK = 'send-missed-settlement-mail'

  # How long after a settlement this job keeps trying. A mail server that
  # refuses for a week needs a person anyway, and a cook's statement is
  # about one settlement among many.
  WINDOW = 7.days

  # Reported when a settlement leaves the window with a mail not sent.
  class GaveUp < StandardError; end

  def run
    # The moment this run started, the one its run record keeps, not the
    # moment the work began. The next run looks back from the recorded
    # moment, so this run's window has to end there too. Until 2026-10-10
    # it ended when the work began, after the healthchecks.io ping, and a
    # settlement that left the window in between was reported twice.
    now = started_at
    # This run has no row yet (RecurringJob writes it at the end), so on
    # the first run there is none, and the floor is now.
    first_run = JobRun.where(name: self.class.run_name).minimum(:started_at) || now
    open_from = [now - WINDOW, first_run].max
    open = settled(from: open_from)

    cooks_queued = Reconciliation.where(id: NotifyCooksJob.cooks_owed(open).keys)
    cooks_queued.each { |reconciliation| NotifyCooksJob.perform_later(reconciliation) }
    house_queued = CommonHouseMailJob.not_sent(open)
    house_queued.each { |reconciliation| CommonHouseMailJob.perform_later(reconciliation) }

    left = left_the_window_since_the_last_run(first_run, open_from)
    cooks_gave_up = NotifyCooksJob.cooks_owed(left)
    cooks_gave_up.each { |id, cooks| report_cooks_gave_up(id, cooks) }
    house_gave_up = CommonHouseMailJob.not_sent(left).pluck(:id)
    house_gave_up.each { |id| report_house_gave_up(id) }

    { cook_mail_queued: cooks_queued.map(&:id), cook_mail_gave_up: cooks_gave_up.keys,
      common_house_mail_queued: house_queued.map(&:id), common_house_mail_gave_up: house_gave_up }
  end

  private

  def settled(from:, before: nil)
    Reconciliation.where(created_at: from...before)
  end

  # The settlements that left the window between the last good run and
  # this one. A failed or missed run moves nothing: the next good run
  # looks back to the last good one. None on the first run, which has no
  # last run to look back to.
  def left_the_window_since_the_last_run(first_run, open_from)
    last_good = JobRun.succeeded.where(name: self.class.run_name).maximum(:started_at)
    return Reconciliation.none if last_good.nil?

    settled(from: [last_good - WINDOW, first_run].max, before: open_from)
  end

  def report_cooks_gave_up(reconciliation_id, cooks)
    error = GaveUp.new(
      "Reconciliation ##{reconciliation_id}: #{cooks} #{'cook'.pluralize(cooks)} still without the cook mail " \
      "after #{WINDOW.inspect}, and nothing tries again. " \
      "To send it: NotifyCooksJob.perform_later(Reconciliation.find(#{reconciliation_id}))"
    )
    Rails.error.report(error, handled: true, severity: :error,
                              context: { reconciliation_id: reconciliation_id, cooks_not_mailed: cooks })
  end

  def report_house_gave_up(reconciliation_id)
    error = GaveUp.new(
      "Reconciliation ##{reconciliation_id}: the common house mail is still not sent after #{WINDOW.inspect}, " \
      "and nothing tries again. To send it: CommonHouseMailJob.perform_later(Reconciliation.find(#{reconciliation_id}))"
    )
    Rails.error.report(error, handled: true, severity: :error,
                              context: { reconciliation_id: reconciliation_id, common_house_not_mailed: true })
  end
end
