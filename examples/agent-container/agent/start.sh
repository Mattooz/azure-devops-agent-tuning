#!/bin/bash
# Variant B entrypoint: register an ephemeral agent, run exactly one job, deregister.
# The PAT lives only in the podman secret file; it is exported (as VSTS_AGENT_INPUT_TOKEN) only while
# config.sh runs, and never reaches run.sh or the job steps.
#
# Environment (passed by the supervisor with -e):
#   AZP_AGENT_NAME  unique name of this agent (required)
#   AZP_URL         the organization URL, https://dev.azure.com/<org> (required)
#   AZP_POOL        the agent pool to register into (required)
#   AZP_SECRET_FILE the PAT file (default /run/secrets/agent-bench-azp-token)
# Self-update: the agent may be asked to update itself when Azure DevOps ships a newer version; in an
# ephemeral container that just ends the process, the container exits, and the supervisor starts a fresh
# one from the image (rebuild the image to move to a newer agent). config.sh 5.281.1 has no
# --disableupdate flag in its help, so none is passed.
set -u
: "${AZP_AGENT_NAME:?AZP_AGENT_NAME required}"
: "${AZP_URL:?AZP_URL required}"
: "${AZP_POOL:?AZP_POOL required}"
SECRET="${AZP_SECRET_FILE:-/run/secrets/agent-bench-azp-token}"
cd /azp/agent

token() { tr -d '\r\n' < "$SECRET"; }

deregister() {
  # Token re-read from the secret file, scoped to this one command.
  VSTS_AGENT_INPUT_TOKEN="$(token)" ./config.sh remove --unattended --auth pat >/dev/null 2>&1
}

child=
on_term() {
  # SIGTERM/SIGINT: stop the listener (it cancels a running job), then deregister.
  [ -n "$child" ] && kill -TERM "$child" 2>/dev/null && wait "$child" 2>/dev/null
  deregister
  exit 143
}
trap on_term TERM INT

VSTS_AGENT_INPUT_TOKEN="$(token)" ./config.sh --unattended --url "$AZP_URL" --auth pat \
  --pool "$AZP_POOL" --agent "$AZP_AGENT_NAME" --work /azp/_work --replace --acceptTeeEula \
  >/dev/null || { echo "config.sh failed" >&2; exit 1; }
unset VSTS_AGENT_INPUT_TOKEN

./run.sh --once &
child=$!
wait "$child"
rc=$?
child=
deregister
exit "$rc"
