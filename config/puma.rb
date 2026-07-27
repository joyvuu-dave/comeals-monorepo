# frozen_string_literal: true

# One thread because nothing needs more — roughly 30 residents, one dyno.
# This is a throughput setting, NOT a safety mechanism. It does not protect
# the money code and never did: `reconciliations:create` runs in a separate
# process (`heroku run rake`), so a settlement can already commit in the
# middle of a request at 1 thread and 0 workers. What actually keeps the
# books correct is `SELECT ... FOR UPDATE` on the meal row, the
# compare-and-swap in Reconciliation#assign_meals, and the immutability
# triggers in the database.
#
# Read docs/adr/0003-concurrency-on-the-money-path.md before changing this.
# There is one known open hole (ActiveAdmin writes bills without the meal
# lock) that exists at any thread count — raising this number does not
# create it, and leaving it at 1 does not prevent it.
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
# For the record, because the history is easy to misread: this app ran
# multi-threaded from 2017 to April 2026, and ran 2 workers × 1 thread for
# nine days in April 2026 (07fae93 through a2eb8b9). Concurrent requests are
# not new territory here.
#
workers ENV.fetch('WEB_CONCURRENCY', 0).to_i

# Allow puma to be restarted by `bin/rails restart` command.
plugin :tmp_restart
