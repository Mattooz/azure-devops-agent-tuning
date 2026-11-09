#!/usr/bin/env bash
# Status of one Azure Pipelines run: the build's status and result, then its jobs and any failed
# task with its first issue (first 300 characters).
#
# Usage: run-status.sh [<org> <project> <build-id>]
#   or set ADO_ORG, ADO_PROJECT and BUILD_ID instead of the arguments.
# Credentials: AZDO_PAT_FILE (a file with the PAT, preferred) or AZDO_PAT (the token itself).
# The PAT goes to curl through a config on stdin, never in its arguments.
set -euo pipefail

ORG="${1:-${ADO_ORG:?set ADO_ORG or pass <org>}}"
PROJECT="${2:-${ADO_PROJECT:?set ADO_PROJECT or pass <project>}}"
BUILD="${3:-${BUILD_ID:?set BUILD_ID or pass <build-id>}}"
BASE="https://dev.azure.com/$ORG/$PROJECT/_apis/build/builds/$BUILD"

pat() {
  if [ -n "${AZDO_PAT_FILE:-}" ]; then
    tr -d '\r\n' < "$AZDO_PAT_FILE"
  else
    printf '%s' "${AZDO_PAT:?set AZDO_PAT_FILE or AZDO_PAT}"
  fi
}
api() { printf 'user = ":%s"\n' "$(pat)" | curl -sS -K - --max-time 30 "$@"; }

api "$BASE?api-version=7.1" | jq -c '{status, result}'
api "$BASE/timeline?api-version=7.1" | jq -r '
  .records[]
  | select(.type == "Job" or .type == "Checkpoint" or ((.issues | length) > 0 and .result == "failed"))
  | "\(.type) \(.name) \(.state) \(.result) \((.issues // [])[0].message // "" | .[0:300])"'
