#!/bin/bash
# Warm pool of variant B: keeps N ephemeral agent containers (run --once) registered and listening
# in one Azure DevOps agent pool, and removes dead agent registrations. No orchestrator: the state
# is the podman labels plus the pool's REST listing.
#
# Environment (in the unit's EnvironmentFile, see systemd/agent-bench-b-supervisor.service):
#   ADO_ORG_URL    https://dev.azure.com/<org>                       (required)
#   ADO_POOL_ID    numeric id of the pool, from the pool's settings  (required)
#   ADO_POOL_NAME  name of the same pool; the agents register into it (required)
#   N              number of warm agents (default 2)
#   AGENT_IMAGE    default localhost/agent-bench-toolchain-agent:1
#   TOKEN_FILE     file with the PAT (default /opt/agent-bench/secrets/azdo_pat)
set -u
: "${ADO_ORG_URL:?set ADO_ORG_URL, e.g. https://dev.azure.com/<org>}"
: "${ADO_POOL_ID:?set ADO_POOL_ID to the numeric id of the pool}"
: "${ADO_POOL_NAME:?set ADO_POOL_NAME to the name of the pool}"
N="${N:-2}"
IMAGE="${AGENT_IMAGE:-localhost/agent-bench-toolchain-agent:1}"
SECRET=agent-bench-azp-token
TOKEN_FILE="${TOKEN_FILE:-/opt/agent-bench/secrets/azdo_pat}"
POOL_API="$ADO_ORG_URL/_apis/distributedtask/pools/$ADO_POOL_ID/agents"
MIN_AGE=120        # seconds a registration must be old before it may be removed (container may still be starting)
STOP_TIMEOUT=90    # grace for the container to deregister itself on SIGTERM

log() { echo "$(date +%T) $*"; }

# Names of this supervisor's containers (running or not), one per line.
live_names() { podman ps --filter label=agent-bench=b --filter status=running --format '{{.Names}}'; }

# curl with the PAT read from the file via stdin config: never in argv.
api() { printf 'user = ":%s"\n' "$(tr -d '\r\n' < "$TOKEN_FILE")" | curl -sS -K - --max-time 30 "$@"; }

start_one() {
  local name="agent-bench-b-$(head -c3 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  # The *_IN_UNSUPPORTED_SYSTEM knobs make the agent skip its per-step glibc probes of its node
  # binaries (node -v) and the telemetry event each probe publishes (a new connection each); the
  # image is glibc-based, so the probes would only ever say "supported" (see docs/01). The same
  # knobs are set on variant A's unit, so the two setups stay comparable.
  # Host network: not needed for speed (measured: no difference with the rootless network); it
  # only keeps the agent's networking like variant A's. With one parallel job a job's Postgres
  # on 55432 cannot clash with another's; with more, drop it or give each job its own port.
  # The diag mount keeps the worker logs after the container is gone (docs/05).
  # --cpus/--memory: the same limits as the job containers of variant A (container.options).
  podman run -d --rm --name "$name" --label agent-bench=b --secret "$SECRET" --network host \
    -v /opt/agent-bench/diag-b:/azp/agent/_diag:U \
    -e AZP_AGENT_NAME="$name" -e AZP_URL="$ADO_ORG_URL" -e AZP_POOL="$ADO_POOL_NAME" \
    -e AGENT_USE_NODE20_IN_UNSUPPORTED_SYSTEM=true -e AGENT_USE_NODE24_IN_UNSUPPORTED_SYSTEM=true \
    --cpus 6 --memory 14g "$IMAGE" >/dev/null \
    && log "started $name" || log "start of $name failed"
}

# Remove agents named agent-bench-b-* that are offline, not a live container, and registered > MIN_AGE ago.
# A container that exits between the list and the DELETE is harmless (it deregisters itself; a 404 is ignored);
# an agent registered by a container not yet listed is protected by the age check.
cleanup_pool() {
  local min_age="${1:-$MIN_AGE}" live now json
  live=" $(live_names | tr '\n' ' ') "
  now=$(date +%s)
  json=$(api "$POOL_API?api-version=7.1") || { log "pool list failed"; return; }
  echo "$json" | jq -r '.value[]? | select(.name|startswith("agent-bench-b-")) | select(.status=="offline") | "\(.id) \(.name) \(.createdOn)"' |
  while read -r id name created; do
    case "$live" in *" $name "*) continue;; esac
    [ $((now - $(date -d "$created" +%s))) -ge "$min_age" ] || continue
    api -o /dev/null -X DELETE "$POOL_API/$id?api-version=7.1" && log "removed stale agent $name ($id)"
  done
}

# Graceful stop: SIGTERM lets each container deregister; then sweep the pool.
shutdown() {
  log "stopping"
  local names; names=$(live_names)
  [ -n "$names" ] && echo "$names" | xargs -r -P8 -n1 podman stop -t "$STOP_TIMEOUT" >/dev/null 2>&1
  cleanup_pool 0
  exit 0
}
trap shutdown TERM INT

log "supervisor up, N=$N"
while true; do
  # Containers are --rm, so an exited one is already gone; also clear leftovers of a crashed run.
  podman ps -a --filter label=agent-bench=b --filter status=exited --filter status=created --format '{{.Names}}' | xargs -r podman rm -f >/dev/null 2>&1
  running=$(live_names | grep -c .)
  for ((i = running; i < N; i++)); do start_one; done
  cleanup_pool
  sleep 5 & wait $!
done
