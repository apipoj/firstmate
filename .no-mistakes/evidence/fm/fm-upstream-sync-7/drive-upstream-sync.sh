#!/usr/bin/env bash
# Disposable product drive for the upstream-sync merge. Not a repository test.
set -u
ROOT="{run-worktree}"
EVIDENCE="~/.no-mistakes/evidence/01M7AWVZDDPZGTCB85JM0K7TDZ"
cd "$ROOT"
REAL_GIT=$(command -v git)
REAL_JQ=$(command -v jq)
LAB_LIST="${TMPDIR:-/tmp}/fm-upstream-sync-labs.$$"
: > "$LAB_LIST"

cleanup() {
  local lab
  if [ -f "$LAB_LIST" ]; then
    while IFS= read -r lab; do
      [ -n "$lab" ] || continue
      rm -rf "$lab"
    done < "$LAB_LIST"
    rm -f "$LAB_LIST"
  fi
  rm -rf "${TMPDIR:-/tmp}"/fm-lab.* 2>/dev/null || true
}
trap cleanup EXIT

new_lab() {
  local lab
  lab=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
  bin/fm-lab-home.sh create "$lab" >/dev/null
  mkdir -p "$lab/tmux" "$lab/user-home"
  printf '%s\n' "$lab" >> "$LAB_LIST"
  printf '%s\n' "$lab"
}

install_curl_shim() {
  local lab=$1
  mkdir -p "$lab/fakebin"
  cat > "$lab/fakebin/curl" <<'SH'
#!/usr/bin/env bash
log=${FM_CURL_LOG:?}
statef=${FM_CURL_LOG}.state
out='' method=GET url='' data=''
[ -f "$statef" ] || printf '%s\n' OPEN > "$statef"
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) out=$2; shift 2 ;;
    -w) shift 2 ;;
    -X) method=$2; shift 2 ;;
    -H)
      if [ "$2" = @/dev/fd/3 ]; then
        IFS= read -r _ <&3 || true
      fi
      shift 2
      ;;
    --data-binary) data=${2#@}; shift 2 ;;
    --max-time) shift 2 ;;
    -s|-S|-sS|--silent|--show-error) shift ;;
    -*) shift ;;
    *) url=$1; shift ;;
  esac
done
case "$url" in
  *api.bitbucket.org*) ;;
  *)
    printf 'BLOCKED %s %s\n' "$method" "$url" >> "$log"
    echo "refusing non-bitbucket url" >&2
    exit 28
    ;;
esac
printf '%s %s\n' "$method" "$url" >> "$log"
[ -z "$data" ] || printf 'BODY %s\n' "$(cat "$data")" >> "$log"
rel=${url#https://api.bitbucket.org/2.0/repositories/}
code=200
body='{}'
draft=${FM_BB_DRAFT:-false}
sha=${FM_BB_SHA:-0123456789abcdef0123456789abcdef01234567}
short=${sha:0:12}
pr_state=$(cat "$statef")
case "$method $rel" in
  "GET "*/pullrequests/*)
    body=$(printf '{"type":"pullrequest","id":5,"state":"%s","draft":%s,"source":{"commit":{"hash":"%s"}}}' "$pr_state" "$draft" "$short")
    ;;
  "GET "*/commit/*/statuses*)
    body='{"values":[{"state":"SUCCESSFUL","key":"ci","name":"ci"}]}'
    ;;
  "GET "*/commit/*)
    body=$(printf '{"hash":"%s"}' "$sha")
    ;;
  "POST "*/pullrequests/*/merge)
    printf '%s\n' MERGED > "$statef"
    body='{"state":"MERGED"}'
    code=200
    ;;
  *)
    code=404
    body='{"error":{"message":"unscripted"}}'
    ;;
esac
[ -z "$out" ] || printf '%s' "$body" > "$out"
printf '%s' "$code"
exit 0
SH
  chmod +x "$lab/fakebin/curl"
  printf '#!/bin/sh\nexec %q "$@"\n' "$REAL_JQ" > "$lab/fakebin/jq"
  chmod +x "$lab/fakebin/jq"
}

install_git_logger() {
  local lab=$1
  cat > "$lab/fakebin/git" <<SH
#!/bin/sh
printf '%s\n' "git \$*" >> "\$FM_GIT_LOG"
exec $(printf '%q' "$REAL_GIT") "\$@"
SH
  chmod +x "$lab/fakebin/git"
}

seed_task() {
  local lab=$1 id=$2
  mkdir -p "$lab/wt" "$lab/project" "$lab/state"
  git -C "$lab/wt" init -q
  git -C "$lab/wt" config user.email fmtest@example.invalid
  git -C "$lab/wt" config user.name fmtest
  git -C "$lab/wt" commit -q --allow-empty -m init
  printf '%s\n' \
    "window=fm-$id" \
    "worktree=$lab/wt" \
    "project=$lab/project" \
    "kind=ship" \
    "mode=no-mistakes" > "$lab/state/$id.meta"
  cp "$ROOT/.tasks.toml" "$lab/.tasks.toml"
  printf '%s\n' '## In flight' '' '## Queued' '' '## Done' > "$lab/data/backlog.md"
  printf 'BITBUCKET_EMAIL=%s\nBITBUCKET_API_TOKEN=%s\n' 'bot@example.invalid' 'tok-not-a-real-token' > "$lab/.env"
  chmod 600 "$lab/.env"
}

run_bounded() {
  perl -e 'my $t = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV } local $SIG{ALRM} = sub { kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; exit 124 }; alarm $t; waitpid $pid, 0; exit($? >> 8)' "$@"
}

env_clean() {
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE \
    -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE \
    -u FM_PROJECTS_OVERRIDE -u BITBUCKET_EMAIL -u BITBUCKET_API_TOKEN \
    -u GH_TOKEN -u GITHUB_TOKEN "$@"
}

bounded() {
  local t=$1
  shift
  run_bounded "$t" env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE \
    -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE \
    -u FM_PROJECTS_OVERRIDE -u BITBUCKET_EMAIL -u BITBUCKET_API_TOKEN \
    -u GH_TOKEN -u GITHUB_TOKEN "$@"
}

section() { printf '\n===== %s =====\n' "$1"; }

{
  section "merge object"
  git cat-file -p HEAD | head -8
  echo "first-parent $(git rev-parse HEAD^1)"
  echo "second-parent $(git rev-parse HEAD^2)"
  echo "expected-fork-tip 52f890f3922acfc1a95a2025fd52c764bc8d7cd4"
  echo "expected-upstream 427056c4181c41074ad24f051f79919330df0fa5"
  echo -n "unique-commits-not-in-either-parent "
  git rev-list --count HEAD ^52f890f3922acfc1a95a2025fd52c764bc8d7cd4 ^427056c4181c41074ad24f051f79919330df0fa5
  echo -n "upstream-commits-now-contained "
  git rev-list --count 52f890f3922acfc1a95a2025fd52c764bc8d7cd4..427056c4181c41074ad24f051f79919330df0fa5
  git merge-base --is-ancestor 427056c4181c41074ad24f051f79919330df0fa5 HEAD && echo "upstream tip is an ancestor (not rewritten)"
  git merge-base --is-ancestor 52f890f3922acfc1a95a2025fd52c764bc8d7cd4 HEAD && echo "fork tip is first-parent ancestor"
  echo "pr6-parents $(git rev-parse 8f8f5ad4^1) $(git rev-parse 8f8f5ad4^2)"
  echo "pr6-subject $(git log -1 --format=%s 8f8f5ad4)"
  echo "this-subject $(git log -1 --format=%s HEAD)"
  if git cat-file -e 52f890f3:bin/fm-park.sh 2>/dev/null; then
    echo "fork-parent-had-fm-park yes"
  else
    echo "fork-parent-had-fm-park no"
  fi
  git cat-file -e HEAD:bin/fm-park.sh && echo "merge-has-fm-park yes"
  git cat-file -e HEAD:bin/fm-bitbucket.sh && echo "merge-has-fm-bitbucket yes"
  echo "conflict-markers $(git grep -l -E '^(<<<<<<<|>>>>>>> )' HEAD -- . | wc -l | tr -d ' ')"
} > "$EVIDENCE/merge-shape.txt"

BB_OUT="$EVIDENCE/bitbucket-away-and-support.txt"
: > "$BB_OUT"
URL="https://bitbucket.org/AcmeWorks/demo-repo/pull-requests/5"

# 1. away refuses before any forge call
lab=$(new_lab)
install_curl_shim "$lab"
seed_task "$lab" task-b1
: > "$lab/curl.log"
{
  section "away enter"
  env_clean FM_HOME="$lab" "$ROOT/bin/fm-afk-contract.sh" enter --words 'merge when green'
  echo "away-mode $(env_clean FM_HOME="$lab" "$ROOT/bin/fm-afk-contract.sh" mode)"
  section "away bitbucket merge"
  rc=0
  out=$(bounded 40 FM_HOME="$lab" FM_CURL_LOG="$lab/curl.log" FM_BB_DRAFT=false \
    PATH="$lab/fakebin:$PATH" HOME="$lab/user-home" \
    "$ROOT/bin/fm-pr-merge.sh" task-b1 "$URL" 2>&1) || rc=$?
  printf 'rc=%s\n%s\n' "$rc" "$out"
  section "curl log after away merge"
  if [ -s "$lab/curl.log" ]; then cat "$lab/curl.log"; else echo "(no forge request)"; fi
  section "merge outcome marker"
  if [ -e "$lab/state/task-b1.pr-poll-merge-notified" ]; then echo "outcome recorded"; else echo "no landed outcome recorded"; fi
} >> "$BB_OUT"

# 2. attended-override does not waive the away refusal
lab=$(new_lab)
install_curl_shim "$lab"
seed_task "$lab" task-b1
: > "$lab/curl.log"
{
  section "away plus attended-override"
  env_clean FM_HOME="$lab" "$ROOT/bin/fm-afk-contract.sh" enter --words 'merge when green' >/dev/null
  rc=0
  out=$(bounded 40 FM_HOME="$lab" FM_CURL_LOG="$lab/curl.log" FM_BB_DRAFT=false \
    PATH="$lab/fakebin:$PATH" HOME="$lab/user-home" \
    "$ROOT/bin/fm-pr-merge.sh" task-b1 "$URL" --attended-override 2>&1) || rc=$?
  printf 'rc=%s\n%s\n' "$rc" "$out"
  section "curl log after override attempt"
  if [ -s "$lab/curl.log" ]; then cat "$lab/curl.log"; else echo "(no forge request)"; fi
} >> "$BB_OUT"

# 3. quiet mode is a present captain: not the away refusal, and a forge read happens
lab=$(new_lab)
install_curl_shim "$lab"
seed_task "$lab" task-b1
: > "$lab/curl.log"
{
  section "quiet enter"
  env_clean FM_HOME="$lab" FM_AFK_MODE=quiet "$ROOT/bin/fm-afk-contract.sh" enter --words 'I am here'
  echo "quiet-mode $(env_clean FM_HOME="$lab" "$ROOT/bin/fm-afk-contract.sh" mode)"
  section "quiet bitbucket merge"
  rc=0
  out=$(bounded 45 FM_HOME="$lab" FM_CURL_LOG="$lab/curl.log" FM_BB_DRAFT=false \
    PATH="$lab/fakebin:$PATH" HOME="$lab/user-home" \
    "$ROOT/bin/fm-pr-merge.sh" task-b1 "$URL" 2>&1) || rc=$?
  printf 'rc=%s\n%s\n' "$rc" "$out"
  section "curl log after quiet merge"
  if [ -s "$lab/curl.log" ]; then cat "$lab/curl.log"; else echo "(no forge request)"; fi
} >> "$BB_OUT"

# 4. missing credentials refuse before any request
lab=$(new_lab)
install_curl_shim "$lab"
seed_task "$lab" task-b1
rm -f "$lab/.env"
: > "$lab/curl.log"
{
  section "missing credentials"
  rc=0
  out=$(bounded 20 FM_HOME="$lab" FM_CURL_LOG="$lab/curl.log" \
    PATH="$lab/fakebin:$PATH" HOME="$lab/user-home" \
    "$ROOT/bin/fm-pr-merge.sh" task-b1 "$URL" 2>&1) || rc=$?
  printf 'rc=%s\n%s\n' "$rc" "$out"
  section "curl log after missing credentials"
  if [ -s "$lab/curl.log" ]; then cat "$lab/curl.log"; else echo "(no forge request)"; fi
} >> "$BB_OUT"

# 5. draft refusal through the real pr-check, nothing armed
lab=$(new_lab)
install_curl_shim "$lab"
seed_task "$lab" task-b1
: > "$lab/curl.log"
{
  section "draft pr-check"
  rc=0
  out=$(bounded 30 FM_HOME="$lab" FM_CURL_LOG="$lab/curl.log" FM_BB_DRAFT=true \
    PATH="$lab/fakebin:$PATH" HOME="$lab/user-home" \
    "$ROOT/bin/fm-pr-check.sh" task-b1 "$URL" 2>&1) || rc=$?
  printf 'rc=%s\n%s\n' "$rc" "$out"
  if [ -e "$lab/state/task-b1.check.sh" ]; then echo "poll armed"; else echo "poll not armed"; fi
  if grep -q '^pr=' "$lab/state/task-b1.meta"; then echo "pr recorded"; else echo "pr not recorded"; fi
  section "curl log after draft check"
  cat "$lab/curl.log"
} >> "$BB_OUT"

# 6. non-draft registration still refreshes remotes (upstream) before the ready gate
lab=$(new_lab)
install_curl_shim "$lab"
install_git_logger "$lab"
seed_task "$lab" task-b1
bare="$lab/origin.git"
git init -q --bare "$bare"
git -C "$lab/wt" remote add origin "$bare"
# HEAD is only local; no remote-tracking ref contains it, so a refresh must fetch.
: > "$lab/curl.log"
: > "$lab/git.log"
{
  section "non-draft pr-check expects a remote refresh then an unreachable-head refusal"
  rc=0
  out=$(bounded 40 FM_HOME="$lab" FM_CURL_LOG="$lab/curl.log" FM_BB_DRAFT=false \
    FM_GIT_LOG="$lab/git.log" \
    PATH="$lab/fakebin:$PATH" HOME="$lab/user-home" \
    "$ROOT/bin/fm-pr-check.sh" task-b1 "$URL" 2>&1) || rc=$?
  printf 'rc=%s\n%s\n' "$rc" "$out"
  if [ -e "$lab/state/task-b1.check.sh" ]; then echo "poll armed"; else echo "poll not armed"; fi
  section "git commands"
  if [ -s "$lab/git.log" ]; then cat "$lab/git.log"; else echo "(git wrapper saw no commands)"; fi
  section "curl log"
  cat "$lab/curl.log"
} >> "$BB_OUT"

# handed_off crew state
CS_OUT="$EVIDENCE/handed-off-crew-state.txt"
: > "$CS_OUT"

install_nm() {
  local lab=$1
  mkdir -p "$lab/fakebin"
  cat > "$lab/fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FM_NM_LOG:?}"
case "${1:-}" in
  axi)
    shift
    if [ "$#" = 0 ]; then
      cat "$FM_NM_OVERVIEW"
      exit 0
    fi
    case "${1:-}" in
      status)
        shift
        if [ "${1:-}" = --run ]; then
          cat "$FM_NM_STATUS_RUN"
        else
          cat "$FM_NM_STATUS"
        fi
        exit 0
        ;;
    esac
    ;;
  runs)
    printf '%s\n' "$FM_NM_RUNS"
    exit 0
    ;;
  daemon)
    printf '%s\n' '  ● daemon running (pid 4242)'
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$lab/fakebin/no-mistakes"
  cat > "$lab/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  list-windows) sed -n 's/^window=[^:]*://p' "${FM_STATE_OVERRIDE:?}"/*.meta 2>/dev/null ;;
  display-message) printf '%%1\n' ;;
  capture-pane) printf 'all quiet\n> \n' ;;
esac
exit 0
SH
  chmod +x "$lab/fakebin/tmux"
}

drive_crew() {
  local label=$1 old_status=$2
  local lab short head overview status runs
  lab=$(new_lab)
  install_nm "$lab"
  mkdir -p "$lab/wt" "$lab/state"
  git -C "$lab/wt" init -q
  git -C "$lab/wt" config user.email fmtest@example.invalid
  git -C "$lab/wt" config user.name fmtest
  git -C "$lab/wt" commit -q --allow-empty -m init
  git -C "$lab/wt" checkout -q -b fm/competing
  head=$(git -C "$lab/wt" rev-parse HEAD)
  short=$(git -C "$lab/wt" rev-parse --short=8 HEAD)
  printf '%s\n' "window=fm:fm-competing" "worktree=$lab/wt" "kind=ship" > "$lab/state/competing.meta"
  overview="$lab/overview.txt"
  status="$lab/status.txt"
  runs="$lab/runs.txt"
  cat > "$overview" <<EOF
count: 2 of 2 total
runs[2]{id,branch,status,head,pr}:
  "01NEW",fm/competing,running,$short,""
  "01OLD",fm/competing,$old_status,$short,""
EOF
  cat > "$status" <<EOF
run:
  id: "01NEW"
  branch: fm/competing
  status: running
  head: "$head"
  pr: ""
  findings: none
  steps[2]{step,status,findings,duration_ms}:
    intent,completed,0,0
    review,running,0,0
EOF
  printf '  running fm/competing %s 2026-09-14 12:01\n  %s fm/competing %s 2026-09-14 12:00\n' \
    "$short" "$old_status" "$short" > "$runs"
  : > "$lab/nm.log"
  {
    section "$label"
    echo "synthetic overview:"
    cat "$overview"
    rc=0
    out=$(bounded 25 FM_HOME="$lab" FM_STATE_OVERRIDE="$lab/state" FM_CREW_STATE_NO_FORGE=1 \
      NM_HOME="$lab/nm-unused" \
      FM_NM_LOG="$lab/nm.log" FM_NM_OVERVIEW="$overview" FM_NM_STATUS="$status" \
      FM_NM_STATUS_RUN="$status" FM_NM_RUNS="$(cat "$runs")" \
      PATH="$lab/fakebin:$PATH" \
      "$ROOT/bin/fm-crew-state.sh" competing 2>&1) || rc=$?
    printf 'rc=%s\n%s\n' "$rc" "$out"
    section "no-mistakes invocations"
    cat "$lab/nm.log"
  } >> "$CS_OUT"
}

drive_crew "newer running beside handed_off" handed_off
drive_crew "newer running beside an unrecognized status" not_a_status

# upstream park command
PK_OUT="$EVIDENCE/upstream-park.txt"
: > "$PK_OUT"
lab=$(new_lab)
seed_task "$lab" task-b1
{
  section "park list on an empty lab"
  rc=0
  out=$(bounded 20 FM_HOME="$lab" "$ROOT/bin/fm-park.sh" list 2>&1) || rc=$?
  printf 'rc=%s\n[%s]\n' "$rc" "$out"
  section "park gate with no recorded pr"
  rc=0
  out=$(bounded 20 FM_HOME="$lab" "$ROOT/bin/fm-park.sh" gate task-b1 2>&1) || rc=$?
  printf 'rc=%s\n%s\n' "$rc" "$out"
  section "park help names the review-park contract"
  env_clean FM_HOME="$lab" "$ROOT/bin/fm-park.sh" --help | head -12
} >> "$PK_OUT"

echo "labs-created $(wc -l < "$LAB_LIST" | tr -d ' ')"
echo "done"
