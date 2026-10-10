# typed: true
# frozen_string_literal: true

# Make sure every cook of every recent settlement gets the cook mail.
#
# NotifyCooksJob mails the cooks after a settlement, and tries a failed
# send again a few times within the first hours. A cook can still miss
# the mail: the mail server is down for longer than that, the job is lost
# (a worker that dies before it runs), or the settlement is not the
# latest one, which is all reconciliations:send_cooking_slot_email
# reaches. So each night this job compares what should be true (every
# cook with an email address has a MailDelivery row) with what is, and
# queues NotifyCooksJob for each settlement that still owes a cook the
# mail. NotifyCooksJob mails only those cooks, so nobody gets it twice.
#
# Only settlements from the last WINDOW are tried. A settlement that
# leaves the window with a cook still not mailed is reported to Bugsnag,
# once, by the first run after it left, with the line to run to send it.
#
# And only settlements made since this job first ran. MailDelivery rows
# for this mail started with NotifyCooksJob, so an older settlement has
# none even when every cook got the mail. Without this floor the first
# night after the deploy would mail every cook of the settlements from
# the week before, a second time.
class SendMissedCookMailJob < RecurringJob
  HEALTHCHECK = 'send-missed-cook-mail'

  # How long after a settlement this job keeps trying. A mail server that
  # refuses for a week needs a person anyway, and a cook's statement is
  # about one settlement among many.
  WINDOW = 7.days

  # Reported when a settlement leaves the window with cooks not mailed.
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

    queued = Reconciliation.where(id: NotifyCooksJob.cooks_owed(settled(from: open_from)).keys)
    queued.each { |reconciliation| NotifyCooksJob.perform_later(reconciliation) }

    gave_up = left_the_window_since_the_last_run(first_run, open_from)
    gave_up.each { |id, cooks| report_gave_up(id, cooks) }

    { queued: queued.map(&:id), gave_up: gave_up.keys }
  end

  private

  def settled(from:, before: nil)
    Reconciliation.where(created_at: from...before)
  end

  # The settlements that left the window between the last good run and
  # this one, with the cooks each still owes the mail. A failed or missed
  # run moves nothing: the next good run looks back to the last good one.
  # Nothing on the first run, which has no last run to look back to.
  def left_the_window_since_the_last_run(first_run, open_from)
    last_good = JobRun.succeeded.where(name: self.class.run_name).maximum(:started_at)
    return {} if last_good.nil?

    NotifyCooksJob.cooks_owed(settled(from: [last_good - WINDOW, first_run].max, before: open_from))
  end

  def report_gave_up(reconciliation_id, cooks)
    error = GaveUp.new(
      "Reconciliation ##{reconciliation_id}: #{cooks} #{'cook'.pluralize(cooks)} still without the cook mail " \
      "after #{WINDOW.inspect}, and nothing tries again. " \
      "To send it: NotifyCooksJob.perform_later(Reconciliation.find(#{reconciliation_id}))"
    )
    Rails.error.report(error, handled: true, severity: :error,
                              context: { reconciliation_id: reconciliation_id, cooks_not_mailed: cooks })
  end
end
