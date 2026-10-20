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
#                config/<VAR>, backups, releases (one status per line),
#                pushed, heroku_sha
#   calls/       one file per call: the name and the arguments, NUL-separated
#   unexpected   every call no rule and no default answered
#   logs, check_runs, real_git
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
    releases)
      [[ " $* " == *" --json "* ]] || unexpected "$@"
      local statuses
      mapfile -t statuses <"$state/releases"
      printf '[{"version":"v700","status":"%s"}]\n' "${statuses[0]:-succeeded}"
      if [ "${#statuses[@]}" -gt 1 ]; then
        printf '%s\n' "${statuses[@]:1}" >"$state/releases"
      else
        : >"$state/releases"
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
    "ls-remote heroku")
      [ -s "$state/heroku_sha" ] && printf '%s\trefs/heads/main\n' "$(<"$state/heroku_sha")"
      ;;
    # The production remote, or the staging app's git address
    # (DEPLOY_APP=comeals-staging). Any other target is unexpected.
    "push heroku" | "push https://git.heroku.com/comeals-staging.git")
      "$real_git" rev-parse HEAD >"$state/pushed"
      # The new release has a worker process type, at 0 when it is new.
      [ "$(<"$state/worker")" = none ] && echo 0 >"$state/worker"
      echo "remote: Verifying deploy... done."
      ;;
    "remote get-url") exec "$real_git" "$@" ;;
    *) unexpected "$@" ;;
  esac
}

case "$name" in
  heroku) heroku_default "$@" ;;
  git) git_default "$@" ;;
  gh)
    [ "${1:-}" = api ] || unexpected "$@"
    cat "$home/check_runs"
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
  bundle | npm | sleep | smoke) ;;
  *) unexpected "$@" ;;
esac
