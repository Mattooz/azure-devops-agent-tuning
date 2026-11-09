#!/usr/bin/env bash
# Mean and maximum duration of the steps of one Azure Pipelines run, from its timeline. A step is a
# task whose name matches STEP_FILTER (default: "step <number>", the names the steps benchmark uses).
# Durations are whole seconds, from the start and finish times of the timeline.
#
# Usage: step-mean.sh [<org> <project> <build-id>]
#   or set ADO_ORG, ADO_PROJECT and BUILD_ID instead of the arguments.
# Credentials: AZDO_PAT_FILE (a file with the PAT, preferred) or AZDO_PAT (the token itself).
# Set STEP_FILTER to a jq regular expression to select other tasks, e.g. STEP_FILTER='^ready'.
set -euo pipefail

ORG="${1:-${ADO_ORG:?set ADO_ORG or pass <org>}}"
PROJECT="${2:-${ADO_PROJECT:?set ADO_PROJECT or pass <project>}}"
BUILD="${3:-${BUILD_ID:?set BUILD_ID or pass <build-id>}}"
FILTER="${STEP_FILTER:-^step [0-9]+$}"
URL="https://dev.azure.com/$ORG/$PROJECT/_apis/build/builds/$BUILD/timeline?api-version=7.1"

pat() {
  if [ -n "${AZDO_PAT_FILE:-}" ]; then
    tr -d '\r\n' < "$AZDO_PAT_FILE"
  else
    printf '%s' "${AZDO_PAT:?set AZDO_PAT_FILE or AZDO_PAT}"
  fi
}

printf 'user = ":%s"\n' "$(pat)" | curl -sS -K - --max-time 30 "$URL" |
  jq -r --arg f "$FILTER" '
    def t: sub("\\.[0-9]+Z$"; "Z") | fromdate;
    [ .records[]
      | select(.type == "Task" and .startTime and .finishTime and (.name | test($f)))
      | ((.finishTime | t) - (.startTime | t)) ]
    | if length == 0 then "no steps matched \($f)"
      else "n=\(length) mean=\((add / length) * 100 | round / 100)s max=\(max)s" end'
