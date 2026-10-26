# shellcheck shell=bash
# The four smoke sign-ins a workflow step that smokes production gets
# from the secrets of the GitHub environment production. A secret that
# is not set reaches the step as an empty value, and the smoke test would
# then skip that login and pass without it. Sourced by
# bin/lib/deploy/smoke-before, bin/lib/deploy/watch-production and
# bin/lib/rollback/smoke.

# Prints the names of the smoke secrets that are empty, on one line, or
# nothing when all four are set. Never prints a value.
missing_smoke_secrets() {
  local name missing=()
  for name in SMOKE_EMAIL SMOKE_PASSWORD SMOKE_ADMIN_EMAIL SMOKE_ADMIN_PASSWORD; do
    [ -n "${!name:-}" ] || missing+=("$name")
  done
  echo "${missing[*]}"
}

# What a step prints before it ends with code 2 for missing secrets.
say_smoke_secrets_missing() {
  echo "Missing smoke secrets: $1. Set them in the GitHub environment production."
}
