#!/usr/bin/env bash
# Live Herdr-lab driver for agy fm-control exit. Not part of the product.
set -u
ROOT="/Users/apipoj/.no-mistakes/worktrees/4e1ea919d81d/01M34T60WZY39D5C720ZJP0SG6"
EVIDENCE="/Users/apipoj/.no-mistakes/evidence/01M34T60WZY39D5C720ZJP0SG6"
LAB_HELPER="$ROOT/bin/fm-herdr-lab.sh"
ORIGINAL_PATH=$PATH
ORIGINAL_HOME=$HOME
LOG="$EVIDENCE/agy-exit-live.log"
: >"$LOG"
exec > >(tee -a "$LOG") 2>&1

note() { printf '\n== %s ==\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; exit 1; }

export FM_GATE_REFUSE_BYPASS=1
# shellcheck source=/dev/null
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

command -v agy >/dev/null || fail "agy is not installed"
command -v herdr >/dev/null || fail "herdr is not installed"
command -v treehouse >/dev/null || fail "treehouse is not installed"
command -v jq >/dev/null || fail "jq is not installed"
[ -d "$ORIGINAL_HOME/.gemini" ] || fail "no ~/.gemini to stage for throwaway HOME"

SESSION=$("$LAB_HELPER" name agyexit)
TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-agy-exit-live.XXXXXX")
FM_HOME="$TMP_ROOT/fm-home"
AGY_HOME="$TMP_ROOT/agy-home"
FAKEBIN="$TMP_ROOT/fakebin"
PROJ="$TMP_ROOT/scratch-project"
ID=agyexitlive1
WT=
CLEANED=0
AGY_STORE="$ORIGINAL_HOME/.gemini/antigravity-cli/settings.json"
AGY_STORE_BAK=

cleanup() {
  local rc=$?
  trap - EXIT
  [ "$CLEANED" = 1 ] && exit "$rc"
  CLEANED=1
  if [ -n "$WT" ] && [ -d "$WT" ]; then
    env HOME="$ORIGINAL_HOME" PATH="$ORIGINAL_PATH" treehouse destroy "$WT" --include-unlanded --include-in-use --yes >/dev/null 2>&1 || true
  fi
  env HOME="$ORIGINAL_HOME" PATH="$ORIGINAL_PATH" "$LAB_HELPER" teardown "$SESSION" || rc=1
  if [ -f "$AGY_STORE_BAK" ]; then cp "$AGY_STORE_BAK" "$AGY_STORE"; fi
  rm -rf "$TMP_ROOT"
  exit "$rc"
}
trap cleanup EXIT

mkdir -p "$FM_HOME/state" "$FM_HOME/data/$ID" "$FM_HOME/config"
printf 'off\n' > "$FM_HOME/config/herdr-presentation-spaces"
AGY_STORE_BAK="$TMP_ROOT/settings.json.bak"
if [ -f "$AGY_STORE" ]; then cp "$AGY_STORE" "$AGY_STORE_BAK"; fi

cat > "$FM_HOME/data/$ID/brief.md" <<'EOF'
# Task
## Captain's intent
Reply with exactly AGY_EXIT_LIVE_OK and nothing else.

## Firstmate spec
Do not edit files. Print AGY_EXIT_LIVE_OK and stop.
EOF

mkdir -p "$PROJ"
git -C "$PROJ" init -q
printf '# scratch\n' > "$PROJ/README.md"
git -C "$PROJ" add README.md
git -C "$PROJ" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
git clone --quiet --bare "$PROJ" "$PROJ.origin.git"
git -C "$PROJ" remote add origin "file://$PROJ.origin.git"

note "provision lab $SESSION"
PATH="$ORIGINAL_PATH" "$LAB_HELPER" provision "$SESSION" || fail "could not provision isolated Herdr lab"

export PATH="$ORIGINAL_PATH"
export FM_HOME
export HERDR_SESSION="$SESSION"
export FM_ROOT_OVERRIDE="$ROOT"
export FM_SPAWN_NO_GUARD=1
export FM_AGY_READY_POLLS=180
export FM_AGY_POLL_INTERVAL=1
export FM_CONTROL_EXIT_WAIT=60

lab() { env PATH="$ORIGINAL_PATH" HOME="$ORIGINAL_HOME" "$LAB_HELPER" run "$SESSION" "$@"; }

classify() {
  local target=$1
  env HOME="$ORIGINAL_HOME" PATH="$ORIGINAL_PATH" FM_HOME="$FM_HOME" HERDR_SESSION="$SESSION" FM_ROOT_OVERRIDE="$ROOT" bash -c '
    set -u
    . "$1/bin/fm-backend.sh"
    fm_backend_composer_state herdr "$2"
  ' _ "$ROOT" "$target"
}

agent_get() {
  lab agent get "$1" 2>/dev/null | jq -c '{agent:(.result.agent.agent // .result.agent), status:(.result.agent.agent_status // empty)}'
}

capture_pane() {
  lab pane read "$1" --source recent --lines 80 2>/dev/null || true
}

note "spawn agy scout $ID"
SPAWN_OUT="$EVIDENCE/spawn.out"
SPAWN_ERR="$EVIDENCE/spawn.err"
set +e
env -u TMUX -u FM_BACKEND \
  "$ROOT/bin/fm-spawn.sh" "$ID" "$PROJ" --scout --harness agy \
  --model gemini-3.8-flash-low --effort low --backend herdr \
  >"$SPAWN_OUT" 2>"$SPAWN_ERR"
spawn_rc=$?
set -e
printf 'spawn rc=%s\n' "$spawn_rc"
sed -n '1,80p' "$SPAWN_OUT"
sed -n '1,80p' "$SPAWN_ERR"
META="$FM_HOME/state/$ID.meta"
if [ -f "$META" ]; then
  cat "$META" | tee "$EVIDENCE/task.meta"
  PANE=$(grep '^herdr_pane_id=' "$META" | cut -d= -f2-)
  WT=$(grep '^worktree=' "$META" | cut -d= -f2-)
fi
if [ -z "${PANE:-}" ]; then
  PANE=$(sed -n 's/.*window \([^ ;]*\).*/\1/p' "$SPAWN_ERR" | tail -n 1)
  PANE=${PANE##*:}
fi
if [ -n "${PANE:-}" ]; then
  note "spawn pane capture $PANE"
  capture_pane "$PANE" | tee "$EVIDENCE/spawn-pane.txt"
  agent_get "$PANE" | tee "$EVIDENCE/spawn-agent.json" || true
fi
[ "$spawn_rc" -eq 0 ] || fail "fm-spawn.sh agy scout failed"
[ -f "$META" ] || fail "spawn wrote no meta"
TARGET="$SESSION:$PANE"
[ -n "$PANE" ] || fail "meta missing herdr_pane_id"
printf 'target=%s worktree=%s\n' "$TARGET" "$WT"

note "wait for idle after launch turn"
idle=0
for i in $(seq 1 180); do
  st=$(lab agent get "$PANE" 2>/dev/null | jq -r '.result.agent.agent_status // empty')
  screen=$(capture_pane "$PANE")
  printf 'poll %s status=%s\n' "$i" "$st"
  case "$st" in
    idle|done)
      case "$screen" in *"? for shortcuts"*) idle=1; break ;; esac
      ;;
  esac
  sleep 1
done
capture_pane "$PANE" | tee "$EVIDENCE/idle-pane.txt"
agent_get "$PANE" | tee "$EVIDENCE/idle-agent.json"
[ "$idle" = 1 ] || fail "agy never settled idle after launch"

IDLE_STATE=$(classify "$TARGET")
printf 'idle composer_state=%s\n' "$IDLE_STATE" | tee "$EVIDENCE/idle-composer.txt"
[ "$IDLE_STATE" = empty ] || fail "idle agy composer_state should be empty, got $IDLE_STATE"

note "pending draft must refuse exit"
lab pane send-text "$PANE" "draft that must refuse exit" >/dev/null \
  || fail "could not type pending draft"
sleep 1
PENDING_STATE=$(classify "$TARGET")
printf 'pending composer_state=%s\n' "$PENDING_STATE" | tee "$EVIDENCE/pending-composer.txt"
capture_pane "$PANE" | tee "$EVIDENCE/pending-pane.txt"
[ "$PENDING_STATE" = pending ] || fail "typed agy draft should be pending, got $PENDING_STATE"

set +e
PENDING_EXIT=$("$ROOT/bin/fm-control.sh" "$ID" exit 2>&1)
pending_rc=$?
set -e
printf 'pending exit rc=%s\n%s\n' "$pending_rc" "$PENDING_EXIT" | tee "$EVIDENCE/pending-exit.txt"
[ "$pending_rc" -ne 0 ] || fail "exit must refuse a pending agy draft"
case "$PENDING_EXIT" in
  *"composer visibly holds pending text"*) ;;
  *) fail "pending refusal did not name pending text" ;;
esac
agent_get "$PANE" | tee "$EVIDENCE/pending-still-alive.json"
case "$(agent_get "$PANE")" in
  *'"status":"idle"'*|*'"status":"done"'*|*'"status":"working"'*) ;;
  *) fail "pending refusal must leave the agy worker alive" ;;
esac

note "clear pending draft with backspaces"
for _ in $(seq 1 40); do
  lab pane send-keys "$PANE" backspace >/dev/null 2>&1 || true
done
sleep 1
CLEARED_STATE=$(classify "$TARGET")
printf 'cleared composer_state=%s\n' "$CLEARED_STATE" | tee "$EVIDENCE/cleared-composer.txt"
if [ "$CLEARED_STATE" != empty ]; then
  note "backspace did not empty composer; submitting draft then waiting idle"
  lab pane send-keys "$PANE" enter >/dev/null || true
  for i in $(seq 1 180); do
    st=$(lab agent get "$PANE" 2>/dev/null | jq -r '.result.agent.agent_status // empty')
    screen=$(capture_pane "$PANE")
    case "$st" in
      idle|done)
        case "$screen" in *"? for shortcuts"*) break ;; esac
        ;;
    esac
    sleep 1
  done
  CLEARED_STATE=$(classify "$TARGET")
  printf 'after-submit composer_state=%s\n' "$CLEARED_STATE"
fi
[ "$CLEARED_STATE" = empty ] || fail "could not restore an empty agy composer, got $CLEARED_STATE"

note "start a long turn then interrupt before idle exit"
lab pane send-text "$PANE" "Write a 1500-word essay on the history of glass. Keep writing until interrupted." >/dev/null \
  || fail "could not type long prompt"
lab pane send-keys "$PANE" enter >/dev/null || fail "could not submit long prompt"
busy=0
for i in $(seq 1 90); do
  st=$(lab agent get "$PANE" 2>/dev/null | jq -r '.result.agent.agent_status // empty')
  printf 'busy-poll %s status=%s\n' "$i" "$st"
  case "$st" in working) busy=1; break ;; esac
  sleep 0.5
done
agent_get "$PANE" | tee "$EVIDENCE/busy-agent.json"
capture_pane "$PANE" | tee "$EVIDENCE/busy-pane.txt"
BUSY_STATE=$(classify "$TARGET")
printf 'busy composer_state=%s\n' "$BUSY_STATE" | tee "$EVIDENCE/busy-composer.txt"
[ "$busy" = 1 ] || fail "long agy turn never became working"
[ "$BUSY_STATE" != empty ] || fail "a working agy composer must not classify empty"

set +e
BUSY_EXIT=$("$ROOT/bin/fm-control.sh" "$ID" exit 2>&1)
busy_exit_rc=$?
set -e
printf 'busy/interrupt exit rc=%s\n%s\n' "$busy_exit_rc" "$BUSY_EXIT" | tee "$EVIDENCE/busy-exit.txt"
if [ "$busy_exit_rc" -eq 0 ]; then
  printf 'control-plane busy exit stopped agy without a settled idle retry\n' | tee "$EVIDENCE/idle-exit.txt"
  printf '%s\n' "$BUSY_EXIT" >> "$EVIDENCE/idle-exit.txt"
else
  note "busy exit refused; interrupt then wait for idle empty and retry"
  lab pane send-keys "$PANE" escape >/dev/null 2>&1 || true
  idle_after=0
  for i in $(seq 1 60); do
    st=$(lab agent get "$PANE" 2>/dev/null | jq -r '.result.agent.agent_status // empty')
    cs=$(classify "$TARGET" 2>/dev/null || printf unknown)
    printf 'post-interrupt poll %s status=%s composer=%s\n' "$i" "$st" "$cs"
    case "$st:$cs" in idle:empty|done:empty) idle_after=1; break ;; esac
    sleep 0.5
  done
  agent_get "$PANE" | tee "$EVIDENCE/post-interrupt-agent.json"
  capture_pane "$PANE" | tee "$EVIDENCE/post-interrupt-pane.txt"
  POST_STATE=$(classify "$TARGET")
  printf 'post-interrupt composer_state=%s\n' "$POST_STATE" | tee "$EVIDENCE/post-interrupt-composer.txt"
  [ "$idle_after" = 1 ] || fail "interrupted agy never settled to idle empty composer"
  set +e
  IDLE_EXIT=$("$ROOT/bin/fm-control.sh" "$ID" exit 2>&1)
  idle_exit_rc=$?
  set -e
  printf 'idle exit rc=%s\n%s\n' "$idle_exit_rc" "$IDLE_EXIT" | tee "$EVIDENCE/idle-exit.txt"
  [ "$idle_exit_rc" -eq 0 ] || fail "fm-control exit on idle empty agy should stop the worker"
  case "$IDLE_EXIT" in
    *"stopped $ID harness=agy"*|*"stopped $ID"*) ;;
    *) fail "idle exit did not report stopped agy" ;;
  esac
fi

note "second exit should be already-stopped"
set +e
SECOND_EXIT=$("$ROOT/bin/fm-control.sh" "$ID" exit 2>&1)
second_rc=$?
set -e
printf 'second exit rc=%s\n%s\n' "$second_rc" "$SECOND_EXIT" | tee "$EVIDENCE/second-exit.txt"
[ "$second_rc" -eq 0 ] || fail "second exit should succeed as already-stopped"
case "$SECOND_EXIT" in
  *already-stopped*) ;;
  *) fail "second exit did not report already-stopped" ;;
esac

note "dead-shell composer after stop"
capture_pane "$PANE" | tee "$EVIDENCE/dead-pane.txt"
DEAD_STATE=$(classify "$TARGET" 2>/dev/null || printf 'unreadable')
printf 'dead composer_state=%s\n' "$DEAD_STATE" | tee "$EVIDENCE/dead-composer.txt"
[ "$DEAD_STATE" != empty ] || fail "a dead shell must not classify empty"

note "live agy exit scenarios passed"
printf 'PASS session=%s pane=%s\n' "$SESSION" "$PANE"
