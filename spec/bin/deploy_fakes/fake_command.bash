# One fake for every outside command bin/deploy runs: heroku, git (only
# the parts that talk to a remote), gh, curl, bundle, npm, sleep and
# bin/smoke. spec/bin/deploy_fakes/deploy_harness.rb copies this file once
# per command name into a folder it puts first on the PATH, so the name it
# runs under says which command it plays. It is bash, not Ruby, because it
# runs about thirty times per deploy and bash starts much faster.
#
# Files under $FAKE_HOME:
#   rules/NNN/   answers the spec set up (cmd, match, and stdout, stderr,
#                exit, times or exec), tried in order
#   state/       the fake production app: maintenance, web, worker (a count,
#                or none when the release has no worker process type),
#                config/<VAR>, backups, release (the newest release's
#                version), releases (the statuses of the release a push
#                makes, one per line), pushed, heroku_sha (the main branch
#                of Heroku's git repository), schema_version (the newest
#                version in schema_migrations, or none), schema_versions
#                (its rows, one a line), tables (the database's tables)
#   calls/       one file per call: the name and the arguments, NUL-separated
#   unexpected   every call no rule and no default answered
#   smoke_env    the credentials the last bin/smoke call was given
#   logs, check_runs (the CI run's jobs), push_output, real_git
set +x

name=${0##*/}
home=$FAKE_HOME
state=$home/state
real_git=$(<"$home/real_git")

# git subcommands that talk to another machine. Every other git command
# runs the real git on the spec's throwaway repository, unrecorded.
if [ "$name" = git ]; then
  case "${1:-}" in
    fetch | pull | push | ls-remote | clone | archive | send-pack | fetch-pack | remote) ;;
    *) exec "$real_git" "$@" ;;
  esac
fi

count=$(<"$home/count")
echo $((count + 1)) >"$home/count"
printf -v call_file '%s/calls/%06d' "$home" "$count"
printf '%s\0' "$name" "$@" >"$call_file"

unexpected() {
  printf '%s %s\n' "$name" "$*" >>"$home/unexpected"
  echo "fake $name: no rule and no default for: $*" >&2
  exit 127
}

# --- Rules: the first one for this command whose pattern matches -------------

args="$*"
rule=""
for dir in "$home"/rules/*/; do
  [ -d "$dir" ] || continue
  [ "$(<"$dir/cmd")" = "$name" ] || continue
  pattern=$(<"$dir/match")
  [[ $args =~ $pattern ]] || continue
  if [ -f "$dir/times" ]; then
    used=0
    [ -f "$dir/used" ] && used=$(<"$dir/used")
    [ "$used" -lt "$(<"$dir/times")" ] || continue
    echo $((used + 1)) >"$dir/used"
  fi
  rule=$dir
  break
done

# A rule that fails leaves the state as it was: the command failed. A rule
# with `exec` runs that command instead (the fake `git fetch heroku`
# fetches from a local folder this way).
if [ -n "$rule" ]; then
  [ -f "$rule/stderr" ] && cat "$rule/stderr" >&2
  if [ -f "$rule/exec" ]; then
    mapfile -d '' -t command <"$rule/exec"
    exec "${command[@]}"
  fi
  status=0
  [ -f "$rule/exit" ] && status=$(<"$rule/exit")
  if [ "$status" -ne 0 ] || [ -f "$rule/stdout" ]; then
    [ -f "$rule/stdout" ] && cat "$rule/stdout"
    exit "$status"
  fi
fi

# --- Defaults, when no rule answered ------------------------------------------

# heroku ps:scale. With no type=count, it prints the formation, like the
# real one ("web=1:Basic worker=1:Basic"). With some, it refuses them all
# when one names a process type the release does not have, as Heroku does,
# and otherwise sets them all.
ps_scale() {
  local worker pair types=() counts=()
  worker=$(<"$state/worker")
  for pair in "$@"; do
    [ "$pair" = -a ] && break
    [[ $pair =~ ^(web|worker)=([0-9]+)$ ]] || unexpected ps:scale "$@"
    if [ "${BASH_REMATCH[1]}" = worker ] && [ "$worker" = none ]; then
      echo " !    Couldn't find that process type (worker)." >&2
      exit 1
    fi
    types+=("${BASH_REMATCH[1]}")
    counts+=("${BASH_REMATCH[2]}")
  done
  if [ "${#types[@]}" -eq 0 ]; then
    printf 'web=%s:Basic' "$(<"$state/web")"
    [ "$worker" = none ] || printf ' worker=%s:Basic' "$worker"
    echo
    return
  fi
  local i
  for i in "${!types[@]}"; do
    echo "${counts[$i]}" >"$state/${types[$i]}"
  done
  echo "Scaling dynos... done"
}

# The app a heroku call names with -a, for the fake's own messages.
app_of() {
  while [ "$#" -gt 0 ]; do
    [ "$1" = -a ] && { echo "${2:-}"; return; }
    shift
  done
}

heroku_default() {
  case "${1:-}" in
    auth:whoami) echo "deployer@example.com" ;;
    config:get)
      [ -f "$state/config/$2" ] && cat "$state/config/$2"
      echo
      ;;
    # heroku config --json: every config var of the fake app.
    config)
      [[ " $* " == *" --json "* ]] || unexpected "$@"
      local file sep=""
      printf '{'
      for file in "$state"/config/*; do
        [ -f "$file" ] || continue
        printf '%s"%s":"%s"' "$sep" "${file##*/}" "$(<"$file")"
        sep=","
      done
      printf '}\n'
      ;;
    config:set)
      local pair
      for pair in "${@:2}"; do
        [[ $pair =~ ^([A-Z_]+)=(.*)$ ]] && printf '%s' "${BASH_REMATCH[2]}" >"$state/config/${BASH_REMATCH[1]}"
      done
      echo "Setting config vars and restarting $(app_of "$@")... done"
      ;;
    maintenance:on)
      echo on >"$state/maintenance"
      echo "Enabling maintenance mode for $(app_of "$@")... done"
      ;;
    maintenance:off)
      echo off >"$state/maintenance"
      echo "Disabling maintenance mode for $(app_of "$@")... done"
      ;;
    ps:scale) ps_scale "${@:2}" ;;
    pg:backups:capture)
      echo $(($(<"$state/backups") + 1)) >"$state/backups"
      printf 'Backing up DATABASE to b%03d... done\n' "$(<"$state/backups")"
      ;;
    pg:backups:info) printf '=== Backup b%03d\nStatus: Completed\n' "$(<"$state/backups")" ;;
    # The newest release first, like the real one. Before a push it is the
    # release that runs, which succeeded. After one, each call takes the
    # next status the spec set up for the new release.
    releases)
      [[ " $* " == *" --json "* ]] || unexpected "$@"
      local statuses status=succeeded
      if [ -s "$state/pushed" ]; then
        mapfile -t statuses <"$state/releases"
        status=${statuses[0]:-succeeded}
        if [ "${#statuses[@]}" -gt 1 ]; then
          printf '%s\n' "${statuses[@]:1}" >"$state/releases"
        else
          : >"$state/releases"
        fi
      fi
      printf '[{"version":%s,"status":"%s"},{"version":%s,"status":"succeeded"}]\n' \
        "$(<"$state/release")" "$status" "$(($(<"$state/release") - 1))"
      ;;
    # heroku ps --json: one dyno per web and worker count, each up on the
    # newest release.
    ps)
      [[ " $* " == *" --json "* ]] || unexpected "$@"
      local type count i sep=""
      printf '['
      for type in web worker; do
        count=$(<"$state/$type")
        [ "$count" = none ] && continue
        for ((i = 1; i <= count; i++)); do
          printf '%s{"name":"%s.%s","type":"%s","state":"up","release":{"version":%s}}' \
            "$sep" "$type" "$i" "$type" "$(<"$state/release")"
          sep=","
        done
      done
      printf ']\n'
      ;;
    # heroku pg:psql -c SQL. For pg_class, the tables, and for
    # 'version=', the rows of schema_migrations, each list ended by
    # end=ok (bin/deploy's check_database_schema). For schema_migrations,
    # the newest version. Otherwise the count of
    # Solid Queue processes with a fresh heartbeat
    # (bin/lib/wait_until_stopped.sh), none by default.
    pg:psql)
      if [[ $* == *pg_class* ]]; then
        printf ' line \n------\n'
        while IFS= read -r table; do printf ' table=%s\n' "$table"; done <"$state/tables"
        printf ' end=ok\n\n'
      elif [[ $* == *"'version='"* ]]; then
        printf ' line \n------\n'
        while IFS= read -r version; do printf ' version=%s\n' "$version"; done <"$state/schema_versions"
        printf ' end=ok\n\n'
      elif [[ $* == *schema_migrations* ]]; then
        printf ' schema \n--------\n newest=%s\n(1 row)\n\n' "$(<"$state/schema_version")"
      else
        printf ' solid_queue \n-------------\n fresh=0\n(1 row)\n\n'
      fi
      ;;
    releases:output) echo "Running release command... migrating" ;;
    run) echo "one-off dyno: ${*:3}" ;;
    logs) cat "$home/logs" ;;
    *) unexpected "$@" ;;
  esac
}

git_default() {
  case "${1:-} ${2:-}" in
    "fetch origin" | "pull --ff-only") ;;
    "ls-remote heroku" | "ls-remote https://git.heroku.com/comeals-staging.git")
      if [ -s "$state/heroku_sha" ]; then
        printf '%s\trefs/heads/main\n' "$(<"$state/heroku_sha")"
      fi
      ;;
    # The production remote, or the staging app's git address
    # (DEPLOY_APP=comeals-staging). Any other target is unexpected. Like
    # the real one, a push of the commit Heroku's git already has builds
    # nothing and makes no release.
    "push heroku" | "push https://git.heroku.com/comeals-staging.git")
      local sha
      sha=$("$real_git" rev-parse HEAD)
      if [ "$sha" = "$(<"$state/heroku_sha")" ]; then
        echo "Everything up-to-date" >&2
        exit 0
      fi
      echo "$sha" >"$state/pushed"
      echo "$sha" >"$state/heroku_sha"
      echo "$sha" >"$state/config/HEROKU_SLUG_COMMIT"
      echo $(($(<"$state/release") + 1)) >"$state/release"
      # The new release has a worker process type, at 0 when it is new.
      [ "$(<"$state/worker")" = none ] && echo 0 >"$state/worker"
      # Heroku's build output reaches git push's standard error.
      cat "$home/push_output" >&2
      echo "remote: Verifying deploy... done."
      ;;
    "remote get-url") exec "$real_git" "$@" ;;
    *) unexpected "$@" ;;
  esac
}

case "$name" in
  heroku) heroku_default "$@" ;;
  git) git_default "$@" ;;
  # gh api: bin/lib/ci-checks asks for the newest CI run (run 7, which
  # passed, unless check_runs is empty: then CI has not run), then for
  # that run's jobs (check_runs).
  gh)
    [ "${1:-}" = api ] || unexpected "$@"
    case "${2:-}" in
      */actions/workflows/ci.yml/runs\?*) [ -s "$home/check_runs" ] && echo '7|completed|success' ;;
      */actions/runs/7/jobs\?*) cat "$home/check_runs" ;;
      *) unexpected "$@" ;;
    esac
    ;;
  # curl -sL -o /dev/null -w "%{http_code}" URL: the site answers 200 only
  # while web runs and maintenance is off, like the real one.
  curl)
    if [ "$(<"$state/web")" -gt 0 ] && [ "$(<"$state/maintenance")" = off ]; then
      printf 200
    else
      printf 503
    fi
    ;;
  # bin/smoke: note the credentials it was given, so a spec can check
  # them without anything printing them.
  smoke)
    for var in SMOKE_EMAIL SMOKE_PASSWORD SMOKE_ADMIN_EMAIL SMOKE_ADMIN_PASSWORD RESIDENT_PASSWORD; do
      printf '%s=%s\n' "$var" "${!var-<unset>}"
    done >"$home/smoke_env"
    ;;
  bundle | npm | npx | sleep) ;;
  *) unexpected "$@" ;;
esac
