# frozen_string_literal: true

# Single thread to eliminate thread-safety concerns in financial code.
# The database connection pool in database.yml tracks this value.
#
max_threads_count = ENV.fetch('RAILS_MAX_THREADS', 1)
min_threads_count = ENV.fetch('RAILS_MIN_THREADS') { max_threads_count }
threads min_threads_count, max_threads_count

# Specifies the `worker_timeout` threshold that Puma will use to wait before
# terminating a worker in development environments.
#
worker_timeout 3600 if ENV.fetch('RAILS_ENV', 'development') == 'development'

# Specifies the `port` that Puma will listen on to receive requests; default is 3000.
#
port ENV.fetch('PORT', 3000)

# Specifies the `environment` that Puma will run in.
#
environment ENV.fetch('RAILS_ENV', 'development')

# Specifies the `pidfile` that Puma will use.
pidfile ENV.fetch('PIDFILE', 'tmp/pids/server.pid')

# Run in single mode (no cluster). With one thread, cluster mode's master
# process would be pure overhead — no parallelism, no copy-on-write sharing.
# If you ever want to scale up, set WEB_CONCURRENCY to 2+ and add back
# `preload_app!` for copy-on-write memory savings across workers.
#
workers ENV.fetch('WEB_CONCURRENCY', 0).to_i

# Allow puma to be restarted by `bin/rails restart` command.
plugin :tmp_restart
