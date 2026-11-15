# typed: true
# frozen_string_literal: true

# An API request that PostgreSQL refuses because its disk is full
# (SQLSTATE 53100, disk_full) is answered 507 Insufficient Storage with a
# message, not 500. RFC 4918: the server "is unable to store the
# representation needed to complete the request". Challenge 30.
#
# The message says nothing was saved, and that is true. The error rolls
# back the transaction it happened in, and a write runs no query after
# its commit except steps that catch their own errors
# (spec/requests/no_query_after_commit_spec.rb). So an error that gets
# here came before the write committed. A key sent with the write is not
# stored either, so the same write sent again with the same key is saved
# once the disk has room.
#
# A disk that fills while PostgreSQL writes a COMMIT stops the whole
# server. The connection drops, and DatabaseUnreachable answers 503 "may
# or may not have been saved", because then the server cannot tell.
#
# No Retry-After: a full disk stays full until someone frees space. It is
# reported as an error, not a warning, because someone has to.
#
# A middleware, like DatabaseUnreachable and for the same reason:
# Rack::Attack writes its counters to solid_cache, in the same database,
# before any controller runs. Paths outside /api/ get the error page.
class DatabaseFull
  MESSAGE = 'The server is out of storage space, so nothing was saved. Try again later.'

  def initialize(app)
    @app = app
  end

  def call(env)
    @app.call(env)
  rescue ActiveRecord::StatementInvalid => e
    path = env.fetch('PATH_INFO')
    raise unless e.cause.is_a?(PG::DiskFull) && path.start_with?('/api/')

    Rails.error.report(e, handled: true, severity: :error, context: { path: path })
    [507, { 'content-type' => 'application/json; charset=utf-8' }, [JSON.generate(message: MESSAGE)]]
  end
end
