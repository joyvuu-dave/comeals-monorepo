# frozen_string_literal: true

# Request throttling for abusive traffic. The goal here is NOT to rate-limit
# normal users — the thresholds below are 10–100× normal use so that a
# legitimate resident fumbling their password will never trip them. Anything
# that does trip them is almost certainly a bot.
#
# Counters live in Rails.cache (dalli / memcached in production).

class Rack::Attack
  # 20 login attempts per IP per 5 minutes. A human retrying a forgotten
  # password maxes out at maybe 5; twenty unambiguous automation.
  throttle('login/ip', limit: 20, period: 5.minutes) do |req|
    req.ip if req.path == '/api/v1/residents/token' && req.post?
  end

  # 10 password-reset requests per IP per hour. Reasonable users hit this
  # once or twice by accident; ten is inbox-spamming.
  throttle('password-reset/ip', limit: 10, period: 1.hour) do |req|
    req.ip if req.path == '/api/v1/residents/password-reset' && req.post?
  end

  # 600 authenticated API requests per IP per minute (= 10/sec sustained).
  # Covers the community-NAT case (many residents behind one public IP) with
  # generous headroom. A single normal user won't approach this.
  throttle('api/ip', limit: 600, period: 1.minute) do |req|
    req.ip if req.path.start_with?('/api/')
  end

  # Custom 429 response — JSON for the API, with a Retry-After header so
  # well-behaved clients back off politely.
  self.throttled_responder = lambda do |req|
    match_data = req.env['rack.attack.match_data']
    period = match_data[:period]
    retry_after = period - (Time.now.to_i % period)

    [
      429,
      { 'Content-Type' => 'application/json', 'Retry-After' => retry_after.to_s },
      [{ message: "Too many requests. Please wait #{retry_after} seconds before trying again." }.to_json]
    ]
  end
end
