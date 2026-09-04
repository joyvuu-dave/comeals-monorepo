# typed: false
# frozen_string_literal: true

# Refuse to boot if the database session is not at SERIALIZABLE.
#
# The isolation level is set per session by the `variables:` block in
# config/database.yml, and everything in ADR 0005 depends on it. The block
# is easy to break quietly: YAML merge keys are shallow, so an environment
# block that declares its own `variables:` hash replaces the whole default
# hash — including the isolation line — and nothing would notice until the
# money code misbehaved. This check notices: a deploy with the wrong
# isolation fails its release health check instead of serving traffic.
#
# The check runs after initialization, not lazily, so the very first thing
# a booted process knows is that its sessions are SERIALIZABLE. When the
# database is unreachable — `rake assets:precompile` on a Heroku build has
# no database — the check skips, because there is no session to verify and
# the process is not going to serve traffic from that state anyway.
Rails.application.config.after_initialize do
  isolation = ActiveRecord::Base.connection.select_value('SHOW default_transaction_isolation')

  unless isolation == 'serializable'
    raise "Database sessions run at #{isolation.inspect}, not serializable. " \
          'The variables: block in config/database.yml has lost ' \
          'default_transaction_isolation — see ADR 0005 and the CAUTION ' \
          'comment on the production block.'
  end
rescue ActiveRecord::ConnectionNotEstablished, ActiveRecord::NoDatabaseError, PG::ConnectionBad
  # No database to check (asset precompile, db:create). Skip.
end
