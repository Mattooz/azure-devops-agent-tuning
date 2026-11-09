#!/usr/bin/env bash
# A throwaway PostgreSQL 17 for the jobs that need a database, started by the job itself, as the
# job's user (initdb + pg_ctl: no container, no root). The same step runs in every agent variant.
#
#   start-postgres.sh        start; sets the pipeline variables DATABASE_URL and AGENT_BENCH_PG_DATA
#   start-postgres.sh stop   stop and delete the data (the last step of every job, condition always())
#
# Durability is off on purpose: the data is thrown away at the end of the job.
set -euo pipefail

HOST=127.0.0.1
PORT=55432

# The PostgreSQL 17 binaries: the ones of pg_config when they are 17, else the Debian/Ubuntu layout
# (the image puts them on PATH already).
find_bindir() {
  local d
  for d in "$(pg_config --bindir 2>/dev/null || true)" /usr/lib/postgresql/17/bin; do
    if [ -n "$d" ] && [ -x "$d/initdb" ] && [ -x "$d/postgres" ] && "$d/postgres" --version | grep -q ' 17\.'; then
      echo "$d"
      return 0
    fi
  done
  return 1
}

if [ "${1:-start}" = stop ]; then
  data=${AGENT_BENCH_PG_DATA:-}
  if [ -z "$data" ] || [ ! -d "$data" ]; then
    echo "start-postgres: nothing to stop"
    exit 0
  fi
  bin=$(find_bindir) || { echo "start-postgres: binaries not found, the server is left to the job's end" >&2; exit 0; }
  "$bin/pg_ctl" -D "$data/pgdata" -m fast -w stop >/dev/null 2>&1 || true
  rm -rf "$data"
  echo "start-postgres: stopped"
  exit 0
fi

bin=$(find_bindir) || { echo "start-postgres: no PostgreSQL 17 binaries (initdb, pg_ctl) found" >&2; exit 1; }

# The temporary directory of the agent (per job), else the system's.
tmp=${AGENT_TEMPDIRECTORY:-${TMPDIR:-/tmp}}
data=$(mktemp -d "$tmp/agent-bench-pg.XXXXXX")

"$bin/initdb" -D "$data/pgdata" -U postgres -A trust -E UTF8 --no-instructions >"$data/initdb.log" 2>&1 || {
  cat "$data/initdb.log" >&2
  exit 1
}

# The socket lives in the data directory: /var/run/postgresql need not exist or be writable.
if ! "$bin/pg_ctl" -D "$data/pgdata" -l "$data/server.log" -w -t 120 \
  -o "-k $data -p $PORT -c listen_addresses=$HOST -c max_connections=500 -c fsync=off -c synchronous_commit=off -c full_page_writes=off" \
  start >/dev/null; then
  cat "$data/server.log" >&2 || true
  exit 1
fi

ready=0
for _ in $(seq 1 60); do
  if "$bin/pg_isready" -h "$HOST" -p "$PORT" -q; then
    ready=1
    break
  fi
  sleep 1
done
if [ "$ready" != 1 ]; then
  echo "start-postgres: postgres did not become ready on $HOST:$PORT" >&2
  cat "$data/server.log" >&2 || true
  exit 1
fi

echo "start-postgres: PostgreSQL 17 on $HOST:$PORT (data in $data, deleted by 'stop')"
echo "##vso[task.setvariable variable=AGENT_BENCH_PG_DATA]$data"
echo "##vso[task.setvariable variable=DATABASE_URL]postgres://postgres:postgres@$HOST:$PORT/postgres"
