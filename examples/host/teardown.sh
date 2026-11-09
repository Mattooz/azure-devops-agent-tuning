#!/usr/bin/env bash
# agent-bench teardown (variants A and B): removes everything of the experiment, in this order:
#   1 variant B: supervisor (graceful stop of its containers), leftover containers labelled agent-bench=b
#   2 variant A: agent agent-bench-a-agent (stop, disable, deregister), job containers of our images
#   3 REST sweep of the pools in ADO_POOL_IDS: agents agent-bench-a-* and agent-bench-b-*
#   4 unit files agent-bench-* in ~/.config/systemd/user
#   5 podman: secret agent-bench-azp-token, images agent-bench-toolchain-agent:1 and agent-bench-toolchain:1,
#     networks vsts_network* (dangling images: never pruned, see step 5)
#   6 everything under /opt/agent-bench, secrets included; the directory itself stays
# Idempotent: every step tolerates "already gone". Usage: teardown.sh [--dry-run]
# --dry-run prints every action and does not stop, delete or remove anything (GET requests only).
# --final-rm is internal: step 6 re-executes a temp copy of this script with it, so the script can delete itself.
#
# Environment:
#   ADO_ORG_URL   https://dev.azure.com/<org>                 (required)
#   ADO_POOL_IDS  space-separated numeric ids of the two pools (required), e.g. "<id-a> <id-b>"
set -u

ROOT=/opt/agent-bench
ORG="${ADO_ORG_URL:-}"
POOLS="${ADO_POOL_IDS:-}"
PAT_FILE=$ROOT/secrets/azdo_pat
UNIT_DIR=$HOME/.config/systemd/user
IMG_TC=localhost/agent-bench-toolchain:1
IMG_AGENT=localhost/agent-bench-toolchain-agent:1
SECRET=agent-bench-azp-token

DRY=0
FINAL=0
FAILS=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY=1 ;;
    --final-rm) FINAL=1 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

[ "$ROOT" = /opt/agent-bench ] || { echo "refusing: ROOT is '$ROOT'" >&2; exit 3; }
[ -n "$ORG" ] || { echo "set ADO_ORG_URL, e.g. https://dev.azure.com/<org>" >&2; exit 3; }
[ -n "$POOLS" ] || { echo "set ADO_POOL_IDS to the space-separated numeric pool ids" >&2; exit 3; }

say()  { echo; echo "== $*"; }
info() { echo "   $*"; }
warn() { echo "   WARN: $*"; FAILS=$((FAILS + 1)); }

# do_ CMD...: runs CMD unless --dry-run; a failure is reported as "already gone or failed" and is not fatal.
do_() {
  if [ "$DRY" = 1 ]; then
    info "[dry-run] $*"
    return 0
  fi
  local out
  if out=$("$@" 2>&1); then
    info "done: $*"
  else
    info "already gone or failed (ignored): $* ${out:+($(printf '%s' "$out" | tail -n 1))}"
  fi
}

# The PAT is read from its file on every use, into a command's stdin or a prefixed env assignment only.
pat() { tr -d '\r\n' < "$PAT_FILE" 2>/dev/null; }

# api ARGS...: curl with the PAT in a config read from stdin (user = ":<PAT>"), never in argv.
api() { printf 'user = ":%s"\n' "$(pat)" | curl -sS -K - --max-time 30 "$@"; }

step1() {
  say "1/6 variant B: supervisor and its containers"
  do_ systemctl --user stop agent-bench-b-supervisor
  # Leftovers the supervisor's stop did not reach (crashed supervisor, container started meanwhile).
  local id
  for id in $(podman ps -aq --filter label=agent-bench=b 2>/dev/null); do
    do_ podman rm -f "$id"
  done
}

step2() {
  say "2/6 variant A: agent agent-bench-a-agent on the host"
  do_ systemctl --user stop agent-bench-a-agent
  do_ systemctl --user disable agent-bench-a-agent
  if [ -x "$ROOT/agents/a-1/config.sh" ]; then
    if [ "$DRY" = 1 ]; then
      info "[dry-run] (cd $ROOT/agents/a-1 && VSTS_AGENT_INPUT_TOKEN=<contents of $PAT_FILE> ./config.sh remove --unattended --auth pat)"
    elif (cd "$ROOT/agents/a-1" && VSTS_AGENT_INPUT_TOKEN="$(pat)" ./config.sh remove --unattended --auth pat >/dev/null 2>&1); then
      info "done: deregistered agent a-1 (config.sh remove)"
    else
      info "config.sh remove failed or agent already gone (the REST sweep in step 3 covers it)"
    fi
  else
    info "no $ROOT/agents/a-1/config.sh: nothing to deregister locally"
  fi
  # Job containers of variant A (the agent runs steps in them); only containers of our two images.
  local img id
  for img in "$IMG_AGENT" "$IMG_TC"; do
    for id in $(podman ps -aq --filter "ancestor=$img" 2>/dev/null); do
      do_ podman rm -f "$id"
    done
  done
}

step3() {
  say "3/6 REST sweep of pools $POOLS: agents agent-bench-a-* and agent-bench-b-*"
  if [ ! -r "$PAT_FILE" ]; then
    warn "no PAT file at $PAT_FILE: sweep skipped"
    return
  fi
  local pool url matches id name status code json
  for pool in $POOLS; do
    url="$ORG/_apis/distributedtask/pools/$pool/agents?api-version=7.1"
    if ! json=$(api "$url"); then
      warn "pool $pool: agent listing failed"
      continue
    fi
    if ! matches=$(printf '%s' "$json" | jq -r '.value[]? | select(.name | startswith("agent-bench-a-") or startswith("agent-bench-b-")) | "\(.id)\t\(.name)\t\(.status)"'); then
      warn "pool $pool: listing is not JSON (auth or network?)"
      continue
    fi
    if [ -z "$matches" ]; then
      info "pool $pool: no agent-bench agents left"
      continue
    fi
    while IFS=$'\t' read -r id name status; do
      if [ "$DRY" = 1 ]; then
        info "[dry-run] would DELETE pool $pool agent $name (id $id, $status)"
        continue
      fi
      if code=$(api -o /dev/null -w '%{http_code}' -X DELETE "$ORG/_apis/distributedtask/pools/$pool/agents/$id?api-version=7.1"); then
        case "$code" in
          2??) info "deleted pool $pool agent $name (id $id, $status): HTTP $code" ;;
          404) info "already gone: pool $pool agent $name (id $id)" ;;
          *)   warn "pool $pool agent $name (id $id): HTTP $code" ;;
        esac
      else
        warn "pool $pool agent $name (id $id): request failed"
      fi
    done <<< "$matches"
  done
}

step4() {
  say "4/6 unit files in $UNIT_DIR"
  do_ systemctl --user disable agent-bench-b-supervisor
  local f found=0
  shopt -s nullglob
  for f in "$UNIT_DIR"/agent-bench-*; do
    found=1
    do_ rm -f -- "$f"
  done
  shopt -u nullglob
  [ "$found" = 1 ] || info "no agent-bench unit files left"
  do_ systemctl --user daemon-reload
  do_ systemctl --user reset-failed
}

step5() {
  say "5/6 podman: secret, images, networks"
  do_ podman secret rm "$SECRET"
  # Agent image first: it is built FROM agent-bench-toolchain:1.
  do_ podman rmi "$IMG_AGENT"
  do_ podman rmi "$IMG_TC"
  local n
  for n in $(podman network ls --format '{{.Name}}' 2>/dev/null | grep '^vsts_network'); do
    do_ podman network rm "$n"
  done
  # Dangling images are NOT removed: none of them carries a label or a name tying it to our Containerfiles,
  # and 'podman image prune' would also hit other images of the user. Listed for manual review only.
  local dangling
  dangling=$(podman images -f dangling=true -q 2>/dev/null | grep -c . || true)
  info "dangling images left untouched (not identifiable as ours): $dangling"
}

step6() {
  say "6/6 everything under $ROOT, secrets included (the directory itself stays)"
  if [ "$FINAL" = 0 ]; then
    if [ "$DRY" = 1 ]; then
      info "[dry-run] would copy this script to a temp file and re-execute it with --final-rm (it deletes itself)"
      info "[dry-run] would delete under $ROOT:"
      ls -A "$ROOT" 2>/dev/null | sed 's/^/     /'
      info "[dry-run] then print: sudo rmdir $ROOT"
      return
    fi
    local tmp
    tmp=$(mktemp "${TMPDIR:-/tmp}/agent-bench-teardown.XXXXXX") || { warn "mktemp failed: step 6 not run"; return; }
    if ! cp -- "$0" "$tmp" || ! chmod 700 "$tmp"; then
      rm -f -- "$tmp"
      warn "could not copy the script to a temp file: step 6 not run"
      return
    fi
    info "re-executing from $tmp (this script's own file is deleted in step 6)"
    exec bash "$tmp" --final-rm
  fi

  if [ "$DRY" = 0 ]; then
    shopt -s dotglob nullglob
    local p
    for p in "$ROOT"/*; do
      if rm -rf -- "$p"; then
        info "deleted $p"
      else
        warn "could not delete $p"
      fi
    done
    shopt -u dotglob nullglob
    rm -f -- "$0"
  fi
  info "left in $ROOT: $(ls -A "$ROOT" 2>/dev/null | wc -l) entries (the directory is kept)"
  info "to remove the empty directory (root-owned parent, needs sudo): sudo rmdir $ROOT"
}

echo "agent-bench teardown on $(hostname), $(date +%F\ %T)"
[ "$DRY" = 1 ] && echo "DRY RUN: nothing is stopped, deleted or removed; only GET requests are sent."

if [ "$FINAL" = 0 ]; then
  step1
  step2
  step3
  step4
  step5
fi
step6

echo
if [ "$FAILS" -gt 0 ]; then
  echo "finished with $FAILS problem(s) listed above"
  exit 1
fi
echo "finished"
