# Waits, after web and the worker are scaled to 0, until no process of
# the running code is left. Source it after bin/lib/json.sh:
#
#   . bin/lib/json.sh
#   . bin/lib/wait_until_stopped.sh
#   wait_until_stopped "$APP" || exit 1
#
# bin/lib/rollback/restore-backup and bin/staging-rehearsal run it
# before they restore a backup. bin/deploy runs it in a maintenance
# deploy before the push, whose release phase runs the migrations. It
# prints what it waits for. When something still runs at the end of the
# time limit, it says what, returns 1, and the caller stops.
#
# It waits for two things, each for at most 36 checks 5 seconds apart
# (3 minutes, plus the time the checks take):
#
# 1. heroku ps lists no web or worker dyno. A dyno takes up to 30
#    seconds to stop after ps:scale returns.
# 2. No Solid Queue process sent a heartbeat in the last 75 seconds.
#    heroku ps alone is not enough: on staging on 2026-10-24 it listed
#    no worker while a worker process that Heroku had restarted still
#    ran Solid Queue, and that process shut down 3 seconds after the
#    restore had dropped its tables (#245).
#
# A check that fails (heroku cannot reach the app or the database) says
# nothing about what runs, so it is asked again, never read as "nothing
# runs".

# Each Solid Queue process writes a heartbeat to its row in
# solid_queue_processes every 60 seconds: the gem's default
# process_heartbeat_interval, which config/ does not change (the spec of
# restore-backup checks both). So a process that still runs has a
# heartbeat less than 60 seconds old. The other 15 seconds allow for a
# slow heartbeat write and for a dyno clock a few seconds behind the
# database's. A process that stops cleanly deletes its row, so then the
# wait ends at once. A process that was killed leaves its row behind,
# and 75 seconds after its last heartbeat the row no longer counts.
SOLID_QUEUE_ALIVE_SECONDS=75
# Rails writes last_heartbeat_at in UTC, in a column without a time
# zone, so now() is turned into UTC too before the two are compared.
SOLID_QUEUE_ALIVE_SQL="SELECT 'fresh=' || count(*) AS solid_queue FROM solid_queue_processes \
WHERE last_heartbeat_at > (now() AT TIME ZONE 'UTC') - interval '$SOLID_QUEUE_ALIVE_SECONDS seconds'"

wait_until_stopped() {
  local app=$1 tries=0 running out reason fresh
  while :; do
    # A failed heroku ps counts as "something runs", so it is asked again.
    running=$(heroku ps -a "$app" --json | json "sum(1 for p in d if p.get('type') in ('web', 'worker'))") ||
      running=unknown
    if [ "$running" = 0 ]; then
      break
    fi
    tries=$((tries + 1))
    if [ "$tries" -ge 36 ]; then
      echo "A web or worker dyno still runs 3 minutes after they were scaled to 0."
      return 1
    fi
    sleep 5
  done
  echo "No web or worker dyno runs. Waiting until no Solid Queue process sends heartbeats."

  tries=0
  while :; do
    if out=$(heroku pg:psql -c "$SOLID_QUEUE_ALIVE_SQL" -a "$app" 2>&1) && [[ $out =~ fresh=([0-9]+) ]]; then
      fresh=${BASH_REMATCH[1]}
      if [ "$fresh" = 0 ]; then
        echo "No Solid Queue process sent a heartbeat in the last $SOLID_QUEUE_ALIVE_SECONDS seconds."
        return 0
      fi
      reason="$fresh Solid Queue process(es) still sent a heartbeat in the last $SOLID_QUEUE_ALIVE_SECONDS seconds,"
      reason="$reason 3 minutes after web and the worker were scaled to 0."
      echo "$fresh Solid Queue process(es) sent a heartbeat in the last $SOLID_QUEUE_ALIVE_SECONDS seconds. Waiting."
    # A database from before Solid Queue has no such table. No Solid
    # Queue process can run on it: a process writes its row there first.
    elif [[ $out == *'relation "solid_queue_processes" does not exist'* ]]; then
      echo "The database has no solid_queue_processes table, so no Solid Queue process runs."
      return 0
    else
      # The last line that is not blank, which is where psql and the
      # Heroku CLI put the error.
      out=$(printf '%s\n' "$out" | grep -v '^[[:space:]]*$' | tail -n 1) || true
      out=${out:-no output}
      reason="Could not read solid_queue_processes for 3 minutes, so it is not known whether a Solid Queue"
      reason="$reason process still runs. The last error: $out"
      echo "Could not read solid_queue_processes ($out). Asking again."
    fi
    tries=$((tries + 1))
    if [ "$tries" -ge 36 ]; then
      echo "$reason"
      return 1
    fi
    sleep 5
  done
}
