# typed: true
# frozen_string_literal: true

# One push to one Pusher channel, run outside the request that caused it.
#
# LiveUpdate used to call Pusher from inside the request, after the
# commit. Pusher's client waits up to 5 seconds each to connect, send and
# receive, so one stalled push could hold a request for 15 seconds, which
# is rack-timeout's whole budget (config/environments/production.rb).
# The person would then see an error for a write that was already in the
# database. Now the request only enqueues this job and answers; Solid
# Queue makes the HTTP call.
#
# A push that fails is tried three times, a few seconds apart, and then
# reported, never raised: the write is committed, and a client that
# missed a push refetches on its next reconnect. The report carries the
# channel so the alert says which screen went stale.
class LivePushJob < ApplicationJob
  ATTEMPTS = 3
  WAIT = 5.seconds

  retry_on StandardError, wait: WAIT, attempts: ATTEMPTS do |job, error|
    Rails.error.report(error, handled: true, context: { channel: job.arguments.first })
  end

  # `options` is nil or `{ socket_id: }`, the browser the push must skip.
  # Pusher is called with three arguments when there are no options, so
  # the call shape is the one it documents for both cases.
  def perform(channel, data, options = nil)
    if options
      Pusher.trigger(channel, 'update', data, options)
    else
      Pusher.trigger(channel, 'update', data)
    end
  end
end
