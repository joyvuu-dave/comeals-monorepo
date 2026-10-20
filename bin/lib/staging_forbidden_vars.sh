# Config vars that must NOT exist on the staging app. Each one is a way
# to reach the real world: mail, healthchecks pings, error reports.
# Staging holds a copy of the production database, with real residents'
# email addresses. bin/staging-rehearsal and bin/deploy (with
# DEPLOY_APP=comeals-staging) both source this and refuse to go on when
# one of these is set. Source it:
#
#   . bin/lib/staging_forbidden_vars.sh
STAGING_FORBIDDEN_VARS=(
  GMAIL_USERNAME
  GMAIL_APP_PASSWORD
  HEALTHCHECKS_PING_KEY
  BUGSNAG_API_KEY
  VITE_BUGSNAG_API_KEY
  SKYLIGHT_AUTHENTICATION
)
