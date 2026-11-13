#!/usr/bin/env bash
# Live drive of the Bitbucket-away branch-prompt change against the real
# firstmate scripts, in disposable lab homes. Not a unit test.
set -u
ROOT="{run-worktree}"
EVID="~/.no-mistakes/evidence/01M7A5G2VQV89MQK6Q73ZN8E5M"
cd "$ROOT" || exit 1

RESULTS="$EVID/scenario-results.txt"
: > "$RESULTS"
note() { printf '%s\n' "$*" | tee -a "$RESULTS" >&2; }

LABS=()
PIDS=()
cleanup() {
  local pid lab
  for pid in "${PIDS[@]+"${PIDS[@]}"}"; do
    [ -n "$pid" ] || continue
    kill -TERM -"$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
  done
  sleep 0.4
  for pid in "${PIDS[@]+"${PIDS[@]}"}"; do
    [ -n "$pid" ] || continue
    kill -KILL -"$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
  done
  # Lab homes are disposable. Evidence files live outside them.
  for lab in "${LABS[@]+"${LABS[@]}"}"; do
    [ -n "$lab" ] && [ -d "$lab" ] || continue
    # Stop a private tmux server only if this lab recorded one. Never the default server.
    if [ -f "$lab/state/.fm-lab-tmux-dir" ]; then
      "$ROOT/bin/fm-lab-home.sh" teardown "$lab" >/dev/null 2>&1 || true
    fi
    rm -rf "$lab"
  done
}
trap cleanup EXIT

mint_lab() {
  local lab
  # TMPDIR on this machine ends in a slash. fm_gate_lab_permitted requires
  # FM_HOME to equal its physical path, so collapse the double slash before
  # the lab is marked and driven.
  lab=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
  lab=$(cd "$lab" && pwd -P)
  "$ROOT/bin/fm-lab-home.sh" create "$lab" >/dev/null
  LABS+=("$lab")
  printf '%s\n' "$lab"
}

# --- scenario 1: running supervision host delivers prompt + away wake --------

note "=== scenario: host delivers branch prompt and away wake ==="
HOST_LAB=$(mint_lab)
note "host lab: $HOST_LAB"

mkdir -p "$HOST_LAB/fakebin"
# Unreachable session backend. Logs the invocation and never calls the real tmux or Herdr.
cat > "$HOST_LAB/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_FAKE_TMUX_LOG:-/dev/null}"
exit 1
SH
chmod +x "$HOST_LAB/fakebin/tmux"
cat > "$HOST_LAB/fakebin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "state: unknown · source: none · fake default"
exit 0
SH
chmod +x "$HOST_LAB/fakebin/fm-crew-state.sh"
ln -sf /bin/bash "$HOST_LAB/fakebin/claude"
: > "$HOST_LAB/config/supervision-host"
printf 'project=demo\nwindow=fm-demo\nharness=claude\nbackend=tmux\n' > "$HOST_LAB/state/demo.meta"
: > "$HOST_LAB/fake-tmux.log"

# Engine the host actually execs. Captures the system prompt file and the wake
# text the host handed it, then finishes the turn through the real drain and
# report scripts so the host ledger can record the away turn.
cat > "$HOST_LAB/engine-stub" <<SH
#!/usr/bin/env bash
set -u
ROOT="$ROOT"
STATE=\${FM_STATE_OVERRIDE:-\$FM_HOME/state}
prompt_file=
wake=
prev=
for a in "\$@"; do
  if [ "\$prev" = --system-prompt-file ]; then
    prompt_file=\$a
  elif [ "\$prev" = -p ]; then
    wake=\$a
  fi
  prev=\$a
done
[ -z "\$prompt_file" ] || cp "\$prompt_file" "\$FM_HOME/captured-prompt.txt"
printf '%s\n' "\$wake" > "\$FM_HOME/captured-wake.txt"
{
  printf 'actor=%s\nprimary=%s\nturn=%s\n' "\${FM_SUPERVISION_ACTOR:-}" "\${FM_SUPERVISION_PRIMARY_HARNESS:-}" "\${FM_BRANCH_REPORT_TURN:-}"
  printf '%s\n' "\$wake"
} > "\$FM_HOME/engine-call.txt"
: > "\$FM_HOME/engine-captured"
drain=\$("\$ROOT/bin/fm-wake-drain.sh" 2>&1) || true
printf '%s\n' "\$drain" > "\$FM_HOME/engine-drain.txt"
ack=\$(printf '%s\n' "\$drain" | sed -n 's/^WAKE_ACK_REQUIRED: after handling completes run bin\\/fm-wake-drain.sh //p' | tail -1)
task=\$(sed -n 's/^tasks=//p' "\$STATE/.supervision-host-turn" | awk '{ print \$1 }')
[ -n "\$task" ] || task=fleet
"\$ROOT/bin/fm-lease.sh" claim "\$task" > "\$FM_HOME/engine-lease.txt" 2>&1 || true
"\$ROOT/bin/fm-branch-report.sh" --task "\$task" --verdict routine --summary "live lab handled \$task" > "\$FM_HOME/engine-report.txt" 2>&1 || true
if [ -n "\$ack" ]; then
  # shellcheck disable=SC2086
  "\$ROOT/bin/fm-wake-drain.sh" \$ack >> "\$FM_HOME/engine-ack.txt" 2>&1 || true
fi
"\$ROOT/bin/fm-lease.sh" release "\$task" >> "\$FM_HOME/engine-lease.txt" 2>&1 || true
printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"num_turns":1,"total_cost_usd":0.01,"usage":{"input_tokens":5,"cache_read_input_tokens":1,"cache_creation_input_tokens":1,"output_tokens":5},"session_id":"lab-stub"}'
exit 0
SH
chmod +x "$HOST_LAB/engine-stub"

# Captain goes away with words that explicitly ask for the Bitbucket merge.
# The script must not parse those words; the host must still deliver the hold.
AWAY_WORDS='merge the Bitbucket pull request when it is green'
enter_out=$(env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE \
  -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  -u BITBUCKET_EMAIL -u BITBUCKET_API_TOKEN -u TMUX -u HERDR_ENV \
  FM_HOME="$HOST_LAB" "$ROOT/bin/fm-afk-contract.sh" enter --words "$AWAY_WORDS" 2>&1) || {
  note "FAIL host: could not record away posture"
  printf '%s\n' "$enter_out" > "$EVID/host-afk-enter.txt"
  exit 1
}
printf '%s\n' "$enter_out" > "$EVID/host-afk-enter.txt"
note "away record written"

set -m
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE \
  -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  -u BITBUCKET_EMAIL -u BITBUCKET_API_TOKEN -u TMUX -u HERDR_ENV -u HERDR_SESSION \
  FM_HOME="$HOST_LAB" \
  FM_CREW_STATE_BIN="$HOST_LAB/fakebin/fm-crew-state.sh" \
  FM_FAKE_TMUX_LOG="$HOST_LAB/fake-tmux.log" \
  PATH="$HOST_LAB/fakebin:$PATH" \
  FM_SUPERVISION_ENGINE_CLAUDE_BIN="$HOST_LAB/engine-stub" \
  FM_SUPERVISION_HOST_PRIMARY=claude \
  FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
  FM_SUPERVISION_ENGINE_GRACE=1 \
  FM_SUPERVISION_HOST_TURN_TIMEOUT=45 \
  HOME="$HOST_LAB" \
  "$HOST_LAB/fakebin/claude" -c '
    printf "%s\n" "$$" > "$FM_HOME/state/.lock"
    printf "%s\n" "$$" > "$FM_HOME/claude.pid"
    "$0" park > "$FM_HOME/host.out" 2>&1
    printf "%s\n" "$?" > "$FM_HOME/host.rc"
  ' "$ROOT/bin/fm-supervision-host.sh" &
HOST_PGID=$!
PIDS+=("$HOST_PGID")
set +m
note "host parent pid $HOST_PGID"

wait_until() {
  local limit=$1 i=0
  shift
  while [ "$i" -lt "$limit" ]; do
    "$@" && return 0
    sleep 0.2
    i=$((i + 1))
  done
  return 1
}
watcher_live() {
  local pid
  pid=$(cat "$HOST_LAB/state/.watch.lock/pid" 2>/dev/null) || return 1
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

if ! wait_until 150 watcher_live; then
  note "FAIL host: watcher did not start"
  echo "--- host.out ---" >> "$RESULTS"
  cat "$HOST_LAB/host.out" 2>/dev/null >> "$RESULTS" || true
  echo "--- supervision-host log ---" >> "$RESULTS"
  cat "$HOST_LAB/state/.supervision-host.log" 2>/dev/null >> "$RESULTS" || true
  cp "$HOST_LAB/host.out" "$EVID/host-out.txt" 2>/dev/null || true
  exit 1
fi
note "watcher live"
printf '%s [at=%s]: step one\n' working "$(date +%s)" >> "$HOST_LAB/state/demo.status"
if ! wait_until 200 test -s "$HOST_LAB/captured-wake.txt"; then
  note "FAIL host: engine never received a wake"
  echo "--- host.out ---" >> "$RESULTS"
  cat "$HOST_LAB/host.out" 2>/dev/null >> "$RESULTS" || true
  echo "--- supervision-host log ---" >> "$RESULTS"
  cat "$HOST_LAB/state/.supervision-host.log" 2>/dev/null >> "$RESULTS" || true
  cp "$HOST_LAB/host.out" "$EVID/host-out.txt" 2>/dev/null || true
  cp "$HOST_LAB/state/.supervision-host.log" "$EVID/host-log.txt" 2>/dev/null || true
  exit 1
fi
note "engine received wake"

# Let the turn settle so the ledger can record posture=away, but the capture
# already exists if settlement fails.
wait_until 100 grep -q $'\thandled\t' "$HOST_LAB/state/.supervision-host.log" || note "note: host did not mark the turn handled within 20s; wake capture still stands"
cp "$HOST_LAB/captured-prompt.txt" "$EVID/host-delivered-prompt.txt"
cp "$HOST_LAB/captured-wake.txt" "$EVID/host-delivered-wake.txt"
cp "$HOST_LAB/engine-call.txt" "$EVID/host-engine-call.txt"
cp "$HOST_LAB/state/.supervision-host.log" "$EVID/host-log.txt" 2>/dev/null || true
cp "$HOST_LAB/fake-tmux.log" "$EVID/host-fake-tmux.log" 2>/dev/null || true
# Postures excerpt the branch actually received.
awk '/^# Postures$/,/^# Discipline$/' "$EVID/host-delivered-prompt.txt" > "$EVID/host-delivered-postures.txt"

# Stop the host before judging, so nothing keeps running.
kill -TERM -"$HOST_PGID" 2>/dev/null || true
sleep 0.5
kill -KILL -"$HOST_PGID" 2>/dev/null || true
if [ -f "$HOST_LAB/state/.watch.lock/pid" ]; then
  kill -TERM "$(cat "$HOST_LAB/state/.watch.lock/pid")" 2>/dev/null || true
fi
note "host stopped"

prompt_ok=1
wake_ok=1
grep -F "any green merge other than a Bitbucket one is mechanically permitted while the record exists." \
  "$EVID/host-delivered-prompt.txt" >/dev/null || { note "FAIL prompt: missing Bitbucket exclusion from the green-merge grant"; prompt_ok=0; }
grep -F "A Bitbucket pull request is never merged while the record exists, green or not" \
  "$EVID/host-delivered-prompt.txt" >/dev/null || { note "FAIL prompt: does not say a Bitbucket pull request is never merged while away"; prompt_ok=0; }
grep -F "so a Bitbucket merge holds for the return." \
  "$EVID/host-delivered-prompt.txt" >/dev/null || { note "FAIL prompt: does not hold a Bitbucket merge for the return"; prompt_ok=0; }
if grep -F "any green merge is mechanically permitted while the record exists." "$EVID/host-delivered-prompt.txt" >/dev/null; then
  note "FAIL prompt: still states the old unqualified green-merge grant"
  prompt_ok=0
fi
grep -F "other than a Bitbucket one" "$EVID/host-delivered-wake.txt" >/dev/null \
  || { note "FAIL wake: does not exclude Bitbucket from the green merge"; wake_ok=0; }
grep -F "stays attended-only while the away record exists and waits for the captain's return" \
  "$EVID/host-delivered-wake.txt" >/dev/null \
  || { note "FAIL wake: does not hold a Bitbucket pull request for the captain's return"; wake_ok=0; }
if grep -F "merges any pull request that is green at its live head" "$EVID/host-delivered-wake.txt" >/dev/null; then
  note "FAIL wake: still grants every green merge, including Bitbucket"
  wake_ok=0
fi
grep -F "$AWAY_WORDS" "$EVID/host-delivered-wake.txt" >/dev/null \
  || { note "FAIL wake: did not carry the captain's away words from the live record"; wake_ok=0; }
grep -F "POSTURE: AWAY." "$EVID/host-delivered-wake.txt" >/dev/null \
  || { note "FAIL wake: missing POSTURE: AWAY"; wake_ok=0; }
# The fake session backend must have been the one called, never a silent success against a real server.
if [ -s "$HOST_LAB/fake-tmux.log" ]; then
  note "fake tmux was invoked ($(wc -l < "$HOST_LAB/fake-tmux.log" | tr -d ' ') calls); it exited 1 and did not reach a real server"
else
  note "note: fake tmux log is empty; watcher may not have listed windows (status-file wake path)"
fi
if [ "$prompt_ok" = 1 ] && [ "$wake_ok" = 1 ]; then
  note "PASS host: delivered prompt and away wake hold Bitbucket merges for the return"
else
  note "FAIL host: delivered text does not match the away Bitbucket contract"
fi

# --- merge drives -------------------------------------------------------------

note "=== scenario: merge script enforcement ==="

write_curl_mock() {
  cat > "$1/fakebin/curl" <<'SH'
#!/usr/bin/env bash
out='' fmt='' method=GET url='' data='' auth=none
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) out=$2; shift 2 ;;
    -w) fmt=$2; shift 2 ;;
    -X) method=$2; shift 2 ;;
    -H)
      if [ "$2" = @/dev/fd/3 ]; then
        IFS= read -r header <&3 || true
        expected="Authorization: Basic $(printf '%s:%s' "$FM_TEST_BB_EMAIL" "$FM_TEST_BB_TOKEN" | base64 | tr -d '\n')"
        if [ "$header" = "$expected" ]; then auth=ok; else auth=bad; fi
      fi
      shift 2
      ;;
    --data-binary) data=${2#@}; shift 2 ;;
    --max-time) shift 2 ;;
    -*) shift ;;
    *) url=$1; shift ;;
  esac
done
# Never fall through to the network. A non-Bitbucket URL is a product bug in this fixture.
case "$url" in
  https://api.bitbucket.org/2.0/*) ;;
  *)
    printf 'REFUSED non-bitbucket url %s\n' "$url" >> "$FM_TEST_BB_LOG"
    exit 7
    ;;
esac
rel=${url#https://api.bitbucket.org/2.0/repositories/}
key=$(printf '%s %s' "$method" "$rel" | tr '/?=& ' '_____')
dir=$FM_TEST_BB_ROUTES
count=$(( $(cat "$dir/$key.count" 2>/dev/null || echo 0) + 1 ))
printf '%s\n' "$count" > "$dir/$key.count"
route="$dir/$key"
[ ! -f "$dir/$key.$count" ] || route="$dir/$key.$count"
[ ! -e "$dir/merge-called" ] || [ ! -f "$dir/$key.merged" ] || route="$dir/$key.merged"
printf '%s %s auth=%s\n' "$method" "$url" "$auth" >> "$FM_TEST_BB_LOG"
[ -z "$data" ] || { printf 'body %s\n' "$(cat "$data")" >> "$FM_TEST_BB_LOG"; }
if [ ! -f "$route" ]; then
  code=404
  body='Not Found'
else
  code=$(head -1 "$route")
  body=$(tail -n +2 "$route")
fi
if [ "$code" = 000 ]; then
  echo "curl: (28) Operation timed out" >&2
  exit 28
fi
case "$method $code $rel" in
  "POST 2"*/merge) : > "$dir/merge-called" ;;
esac
[ -z "$out" ] || printf '%s' "$body" > "$out"
[ "$fmt" != '%{http_code}' ] || printf '%s' "$code"
exit 0
SH
  chmod +x "$1/fakebin/curl"
}

route_key() { printf '%s %s' "$1" "$2" | tr '/?=& ' '_____'; }
route() {
  local file="$1/routes/$(route_key "$2" "$3")${6:+.$6}"
  printf '%s\n%s\n' "$4" "$5" > "$file"
}

WS=AcmeWorks
REPO=demo-repo
PR_ID=5
BB_URL="https://bitbucket.org/$WS/$REPO/pull-requests/$PR_ID"
SHORT=0123456789ab
HEAD_SHA=0123456789abcdef0123456789abcdef01234567
EMAIL=bot@example.invalid
TOKEN=tok-lab-not-real

prepare_merge_lab() {
  local lab=$1
  mkdir -p "$lab/fakebin" "$lab/routes" "$lab/wt" "$lab/user-home"
  printf 'BITBUCKET_EMAIL=%s\nBITBUCKET_API_TOKEN=%s\n' "$EMAIL" "$TOKEN" > "$lab/.env"
  cp "$ROOT/.tasks.toml" "$lab/.tasks.toml"
  printf '%s\n' '## In flight' '' '## Queued' '' '## Done' > "$lab/data/backlog.md"
  git -C "$lab/wt" init -q -b main
  printf '# lab\n' > "$lab/wt/README.md"
  git -C "$lab/wt" add README.md
  git -C "$lab/wt" -c user.name='Firstmate Lab' -c user.email='lab@example.invalid' commit -qm initial
  git -C "$lab/wt" update-ref refs/remotes/origin/main "$(git -C "$lab/wt" rev-parse HEAD)"
  printf '%s\n' \
    "window=fm-task-b1" \
    "worktree=$lab/wt" \
    "project=$lab/project" \
    "kind=ship" \
    "mode=no-mistakes" > "$lab/state/task-b1.meta"
  : > "$lab/curl.log"
  write_curl_mock "$lab"
  ln -sf "$(command -v jq)" "$lab/fakebin/jq"
  ln -sf "$(command -v git)" "$lab/fakebin/git"
  # Green pull request that would merge if the away gate did not refuse first.
  route "$lab" GET "$WS/$REPO/pullrequests/$PR_ID" 200 \
    "{\"type\":\"pullrequest\",\"id\":$PR_ID,\"state\":\"OPEN\",\"draft\":false,\"source\":{\"commit\":{\"hash\":\"$SHORT\"}}}"
  route "$lab" GET "$WS/$REPO/pullrequests/$PR_ID" 200 \
    "{\"type\":\"pullrequest\",\"id\":$PR_ID,\"state\":\"MERGED\",\"draft\":false,\"source\":{\"commit\":{\"hash\":\"$SHORT\"}}}" merged
  route "$lab" GET "$WS/$REPO/commit/$SHORT" 200 "{\"hash\":\"$HEAD_SHA\",\"type\":\"commit\"}"
  route "$lab" GET "$WS/$REPO/commit/$HEAD_SHA/statuses?pagelen=100" 200 \
    '{"values":[{"type":"build","state":"SUCCESSFUL","key":"pipeline"},{"type":"build","state":"SUCCESSFUL","key":"lint"}],"pagelen":100,"size":2,"next":null}'
  route "$lab" POST "$WS/$REPO/pullrequests/$PR_ID/merge" 200 \
    "{\"type\":\"pullrequest\",\"id\":$PR_ID,\"state\":\"MERGED\",\"draft\":false,\"source\":{\"commit\":{\"hash\":\"$SHORT\"}}}"
}

run_merge() {
  local lab=$1 actor=$2 url=$3
  shift 3
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE \
    -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
    -u BITBUCKET_EMAIL -u BITBUCKET_API_TOKEN -u GH_TOKEN -u GITHUB_TOKEN -u TMUX -u HERDR_ENV \
    ${actor:+FM_SUPERVISION_ACTOR="$actor"} \
    FM_TEST_BB_ROUTES="$lab/routes" FM_TEST_BB_LOG="$lab/curl.log" \
    FM_TEST_BB_EMAIL="$EMAIL" FM_TEST_BB_TOKEN="$TOKEN" \
    FM_HOME="$lab" PATH="$lab/fakebin:$PATH" HOME="$lab/user-home" \
    "$ROOT/bin/fm-pr-merge.sh" task-b1 "$url" "$@"
}

merge_posts() {
  grep -c "^POST .*/pullrequests/$PR_ID/merge " "$1/curl.log" 2>/dev/null || true
}

# 2. Branch, away, words say merge the Bitbucket PR when green.
MERGE_LAB=$(mint_lab)
prepare_merge_lab "$MERGE_LAB"
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE \
  -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  -u BITBUCKET_EMAIL -u BITBUCKET_API_TOKEN \
  FM_HOME="$MERGE_LAB" "$ROOT/bin/fm-afk-contract.sh" enter --words "$AWAY_WORDS" >/dev/null
rc=0
out=$(run_merge "$MERGE_LAB" branch "$BB_URL" 2>&1) || rc=$?
{
  printf 'exit=%s\n' "$rc"
  printf '%s\n' "$out"
  echo "--- curl.log ---"
  cat "$MERGE_LAB/curl.log"
} > "$EVID/merge-away-branch.txt"
posts=$(merge_posts "$MERGE_LAB")
away_branch_ok=1
[ "$rc" = 2 ] || { note "FAIL away-branch: exit $rc, expected 2"; away_branch_ok=0; }
printf '%s\n' "$out" | grep -F "attended-only" >/dev/null || { note "FAIL away-branch: refusal did not say attended-only"; away_branch_ok=0; }
printf '%s\n' "$out" | grep -F "waits for the captain's return" >/dev/null || { note "FAIL away-branch: refusal does not wait for the captain"; away_branch_ok=0; }
if printf '%s\n' "$out" | grep -F "immediate merge may run" >/dev/null; then
  note "FAIL away-branch: refusal still invites an immediate merge"
  away_branch_ok=0
fi
[ "$posts" = 0 ] || { note "FAIL away-branch: $posts merge POST(s) were made"; away_branch_ok=0; }
[ ! -e "$MERGE_LAB/state/task-b1.pr-poll-merge-notified" ] || { note "FAIL away-branch: a landed outcome was recorded"; away_branch_ok=0; }
# The green routes were armed. An empty curl log means the refusal happened before any forge read, not after a failed POST.
if [ -s "$MERGE_LAB/curl.log" ]; then
  note "note away-branch: forge was contacted before refusal:"
  cat "$MERGE_LAB/curl.log" >> "$RESULTS"
fi
if [ "$away_branch_ok" = 1 ]; then
  note "PASS away-branch: Bitbucket merge refused before any merge POST; message waits for the captain"
else
  note "FAIL away-branch"
fi

# 3. Same green PR, captain present (record archived), main actor: merge proceeds.
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE \
  -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  FM_HOME="$MERGE_LAB" "$ROOT/bin/fm-afk-contract.sh" archive >/dev/null
[ ! -f "$MERGE_LAB/state/.afk-contract" ] || { note "FAIL attended: away record still present"; }
: > "$MERGE_LAB/curl.log"
rm -f "$MERGE_LAB/routes/merge-called" "$MERGE_LAB/state/task-b1.pr-poll-merge-notified"
rc=0
out=$(run_merge "$MERGE_LAB" "" "$BB_URL" 2>&1) || rc=$?
{
  printf 'exit=%s\n' "$rc"
  printf '%s\n' "$out"
  echo "--- curl.log ---"
  cat "$MERGE_LAB/curl.log"
} > "$EVID/merge-attended-success.txt"
posts=$(merge_posts "$MERGE_LAB")
attended_ok=1
[ "$rc" = 0 ] || { note "FAIL attended: exit $rc, expected 0"; attended_ok=0; }
printf '%s\n' "$out" | grep -F "verified:" >/dev/null || { note "FAIL attended: merge was not verified"; attended_ok=0; }
printf '%s\n' "$out" | grep -F "merged" >/dev/null || { note "FAIL attended: output did not report merged"; attended_ok=0; }
[ "$posts" = 1 ] || { note "FAIL attended: expected 1 merge POST, got $posts"; attended_ok=0; }
if printf '%s\n' "$out" | grep -F "a Bitbucket merge is attended-only" >/dev/null; then
  note "FAIL attended: the away refusal leaked into a present-captain merge"
  attended_ok=0
fi
if [ "$attended_ok" = 1 ]; then
  note "PASS attended: the same green Bitbucket pull request merges when the captain is present"
else
  note "FAIL attended"
fi

# 4. GitHub URL while away must not be refused as a Bitbucket merge.
# Fake gh logs and fails without touching the network or the operator's login.
cat > "$MERGE_LAB/fakebin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_FAKE_GH_LOG"
echo "fake gh: no network" >&2
exit 1
SH
chmod +x "$MERGE_LAB/fakebin/gh"
: > "$MERGE_LAB/gh.log"
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE \
  -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  FM_HOME="$MERGE_LAB" "$ROOT/bin/fm-afk-contract.sh" enter --words 'merge the GitHub pull request when green' >/dev/null
: > "$MERGE_LAB/curl.log"
rc=0
out=$(env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE \
  -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  -u BITBUCKET_EMAIL -u BITBUCKET_API_TOKEN -u GH_TOKEN -u GITHUB_TOKEN -u TMUX \
  FM_SUPERVISION_ACTOR=branch \
  FM_FAKE_GH_LOG="$MERGE_LAB/gh.log" \
  FM_HOME="$MERGE_LAB" PATH="$MERGE_LAB/fakebin:$PATH" HOME="$MERGE_LAB/user-home" \
  "$ROOT/bin/fm-pr-merge.sh" task-b1 "https://github.com/acme/demo/pull/9" 2>&1) || rc=$?
{
  printf 'exit=%s\n' "$rc"
  printf '%s\n' "$out"
  echo "--- gh.log ---"
  cat "$MERGE_LAB/gh.log"
} > "$EVID/merge-github-away.txt"
github_ok=1
if printf '%s\n' "$out" | grep -F "a Bitbucket merge is attended-only" >/dev/null; then
  note "FAIL github-away: a GitHub pull request was refused as a Bitbucket merge"
  github_ok=0
fi
if [ ! -s "$MERGE_LAB/gh.log" ]; then
  note "FAIL github-away: fake gh was never invoked, so the run may not have passed the away gate (exit $rc)"
  github_ok=0
fi
if [ "$github_ok" = 1 ]; then
  note "PASS github-away: GitHub pull request while away was not refused as Bitbucket; fake gh was invoked and made no network call"
else
  note "FAIL github-away"
fi

# 5. Attended branch is still role-refused and never reaches the forge.
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE \
  -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  FM_HOME="$MERGE_LAB" "$ROOT/bin/fm-afk-contract.sh" archive >/dev/null
: > "$MERGE_LAB/curl.log"
rm -f "$MERGE_LAB/routes/merge-called"
rc=0
out=$(run_merge "$MERGE_LAB" branch "$BB_URL" 2>&1) || rc=$?
{
  printf 'exit=%s\n' "$rc"
  printf '%s\n' "$out"
  echo "--- curl.log ---"
  cat "$MERGE_LAB/curl.log"
} > "$EVID/merge-attended-branch.txt"
branch_attended_ok=1
[ "$rc" = 6 ] || { note "FAIL attended-branch: exit $rc, expected role-partition 6"; branch_attended_ok=0; }
printf '%s\n' "$out" | grep -F "supervision branch never performs this action" >/dev/null \
  || { note "FAIL attended-branch: role partition did not refuse"; branch_attended_ok=0; }
posts=$(merge_posts "$MERGE_LAB")
[ "$posts" = 0 ] || { note "FAIL attended-branch: $posts merge POST(s)"; branch_attended_ok=0; }
if [ -s "$MERGE_LAB/curl.log" ]; then
  note "FAIL attended-branch: forge was contacted"
  branch_attended_ok=0
fi
if [ "$branch_attended_ok" = 1 ]; then
  note "PASS attended-branch: an attended branch is still refused before any forge call"
else
  note "FAIL attended-branch"
fi

# 6. GitLab auto-merge while away keeps its own "immediate merge" sentence.
# The Bitbucket wording change must not have rewritten this sibling refusal.
cat > "$MERGE_LAB/fakebin/glab" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_FAKE_GLAB_LOG"
echo "fake glab: no network" >&2
exit 1
SH
chmod +x "$MERGE_LAB/fakebin/glab"
: > "$MERGE_LAB/glab.log"
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE \
  -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  FM_HOME="$MERGE_LAB" "$ROOT/bin/fm-afk-contract.sh" enter --words 'merge the GitLab request when green' >/dev/null
rc=0
out=$(env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE \
  -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  -u BITBUCKET_EMAIL -u BITBUCKET_API_TOKEN -u TMUX \
  FM_SUPERVISION_ACTOR=branch \
  FM_FAKE_GLAB_LOG="$MERGE_LAB/glab.log" \
  FM_HOME="$MERGE_LAB" PATH="$MERGE_LAB/fakebin:$PATH" HOME="$MERGE_LAB/user-home" \
  "$ROOT/bin/fm-pr-merge.sh" task-b1 "https://gitlab.com/acme/demo/-/merge_requests/4" -- --auto-merge 2>&1) || rc=$?
{
  printf 'exit=%s\n' "$rc"
  printf '%s\n' "$out"
  echo "--- glab.log ---"
  cat "$MERGE_LAB/glab.log"
} > "$EVID/merge-gitlab-away-async.txt"
gitlab_ok=1
[ "$rc" = 2 ] || { note "FAIL gitlab-away: exit $rc, expected 2"; gitlab_ok=0; }
printf '%s\n' "$out" | grep -F "only an immediate merge may run" >/dev/null \
  || { note "FAIL gitlab-away: GitLab refusal lost its immediate-merge sentence"; gitlab_ok=0; }
if printf '%s\n' "$out" | grep -F "a Bitbucket merge is attended-only" >/dev/null; then
  note "FAIL gitlab-away: GitLab auto-merge was refused as Bitbucket"
  gitlab_ok=0
fi
if [ -s "$MERGE_LAB/glab.log" ]; then
  note "FAIL gitlab-away: glab was invoked, so the refusal was not before the forge call"
  gitlab_ok=0
fi
if [ "$gitlab_ok" = 1 ]; then
  note "PASS gitlab-away: GitLab auto-merge while away still says only an immediate merge may run, and glab was not called"
else
  note "FAIL gitlab-away"
fi

note "=== done ==="
# Nonzero if any FAIL line was recorded, so the caller can see it. Evidence files stay.
if grep -q '^FAIL ' "$RESULTS"; then
  exit 1
fi
exit 0
