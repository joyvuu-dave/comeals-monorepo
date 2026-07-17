# frozen_string_literal: true

require 'net/http'

# Dead-man's-switch pings for scheduled jobs, via healthchecks.io.
#
# Wrap a job body in Healthcheck.monitor. When the body finishes, the
# job's check gets a success ping. When the body raises, the check gets
# a /fail ping and the error is re-raised. When the job stops running
# entirely — dyno never starts, scheduler entry deleted — no ping
# arrives and healthchecks.io emails after the grace period. That last
# case is the one no code inside the job can ever catch.
#
# Pings are off unless HEALTHCHECKS_PING_KEY is set (production only).
# A ping must never break the job it watches: the pinger swallows its
# own errors. A lost success ping turns into a missed check on the
# healthchecks.io side — a false alarm, not a silent failure.
class Healthcheck
  BASE_URL = 'https://hc-ping.com'
  OPEN_TIMEOUT = 5
  READ_TIMEOUT = 10

  def self.monitor(slug)
    result = yield
    ping(slug)
    result
  rescue StandardError
    ping(slug, state: 'fail')
    raise
  end

  def self.ping(slug, state: nil)
    key = ENV.fetch('HEALTHCHECKS_PING_KEY', nil)
    return if key.blank?

    uri = ping_uri(key, slug, state)
    response = Net::HTTP.start(uri.host, uri.port,
                               use_ssl: true, open_timeout: OPEN_TIMEOUT,
                               read_timeout: READ_TIMEOUT) do |http|
      http.get(uri.request_uri)
    end
    # A rejected ping (bad key, deleted check) means the job is silently
    # unmonitored — the log line is the only trace of that.
    Rails.logger.warn("Healthcheck ping for #{slug} returned #{response.code}") unless response.is_a?(Net::HTTPSuccess)
    response
  rescue StandardError => e
    Rails.logger.warn("Healthcheck ping for #{slug} failed: #{e.class}: #{e.message}")
  end

  # create=1 makes healthchecks.io create the check on first ping
  # (daily period, 1-hour grace), so a new job needs no manual setup.
  def self.ping_uri(key, slug, state)
    state_segment = state ? "/#{state}" : ''
    URI("#{BASE_URL}/#{key}/#{slug}#{state_segment}?create=1")
  end
end
