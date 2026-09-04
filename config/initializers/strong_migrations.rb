# typed: false
# frozen_string_literal: true

# The migration policy behind automated rollback (deploy-confidence
# plan, item 8): every migration must be backward-compatible for one
# release, so `heroku rollback` is always safe as code-only — the
# previous slug must run against the current schema. This gem refuses
# the operations that break that (dropping a column still in use,
# renaming, blocking index builds) at author time. Overriding with
# safety_assured is allowed, but it is a visible mark in the diff that
# says "I checked the rollback story by hand".

# Mark existing migrations as safe
StrongMigrations.start_after = 20_260_810_194_248

# Set timeouts for migrations
# If you use PgBouncer in transaction mode, delete these lines and set timeouts on the database user
StrongMigrations.lock_timeout = 10.seconds
StrongMigrations.statement_timeout = 1.hour

# Analyze tables after indexes are added
# Outdated statistics can sometimes hurt performance
StrongMigrations.auto_analyze = true

# Set the version of the production database
# so the right checks are run in development
# StrongMigrations.target_version = 18

# Add custom checks
# StrongMigrations.add_check do |method, args|
#   if method == :add_index && args[0].to_s == "users"
#     stop! "No more indexes on the users table"
#   end
# end

# Remove invalid indexes when rerunning migrations
# StrongMigrations.remove_invalid_indexes = true

# Make some operations safe by default
# See https://github.com/ankane/strong_migrations#safe-by-default
# StrongMigrations.safe_by_default = true
