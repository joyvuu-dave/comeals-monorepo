# typed: true
# frozen_string_literal: true

# An API request that loses its database connection is answered 503 with
# a Retry-After and a message, not 500 (RFC 9110: the server cannot
# handle the request now, and may be able to later). bin/faults found
# the 500s (challenge 30): a connection cut, a moment when the database
# cannot be reached, a PostgreSQL restart.
#
# A middleware, not a rescue_from in ApiController: Rack::Attack reads
# its counters from solid_cache, which is in the same database, before
# any controller runs. SolidCache rescues ConnectionNotEstablished on its
# own reads, but not ConnectionFailed.
#
# The server cannot tell whether a write it was in the middle of was
# saved: the connection may have dropped while PostgreSQL was committing
# it. So the message does not say that nothing was saved. A write sent
# again with the same Idempotency-Key is safe either way.
#
# Paths outside /api/ get the error page, as before.
class DatabaseUnreachable
  ERRORS = [ActiveRecord::ConnectionNotEstablished, ActiveRecord::ConnectionFailed].freeze
  MESSAGE = 'The server could not reach its database. Your change may or may not have been saved. ' \
            'Try again in a moment.'

  def initialize(app)
    @app = app
  end

  def call(env)
    @app.call(env)
  rescue *ERRORS => e
    raise unless env.fetch('PATH_INFO').start_with?('/api/')

    Rails.error.report(e, handled: true, severity: :warning, context: { path: env.fetch('PATH_INFO') })
    [503, { 'content-type' => 'application/json; charset=utf-8', 'retry-after' => '5' },
     [JSON.generate(message: MESSAGE)]]
  end
end
