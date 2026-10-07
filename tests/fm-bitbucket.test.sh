#!/usr/bin/env bash
# Tests for Bitbucket Cloud pull request support: bin/fm-bitbucket.sh (REST
# access, credentials, state mapping, and error reporting), the bitbucket
# provider in bin/fm-pr-lib.sh's URL parse and record reader, the merge poll in
# bin/fm-pr-poll.sh, arming through bin/fm-pr-check.sh, and the merge path in
# bin/fm-pr-merge.sh.
#
# No test reaches the network. A fake curl on PATH answers every request from
# route files in the case directory, logs each call, and checks the basic-auth
# header it reads from fd 3 against the case's credentials without logging it.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-pr-lib.sh"
fm_git_identity fmtest fmtest@example.invalid

BB="$ROOT/bin/fm-bitbucket.sh"
POLL="$ROOT/bin/fm-pr-poll.sh"
PR_CHECK="$ROOT/bin/fm-pr-check.sh"
PR_MERGE="$ROOT/bin/fm-pr-merge.sh"
TMP_ROOT=$(fm_test_tmproot fm-bitbucket-tests)
REAL_JQ=$(command -v jq) || fail "these tests need jq, which was not found"

WS=AcmeWorks
REPO=demo-repo
PR_ID=5
URL="https://bitbucket.org/$WS/$REPO/pull-requests/$PR_ID"
SHORT=0123456789ab
HEAD_SHA=0123456789abcdef0123456789abcdef01234567
OTHER_SHORT=fedcba987654
OTHER_SHA=fedcba9876543210fedcba9876543210fedcba98
EMAIL=bot@example.invalid
TOKEN=tok-SECRET-value-123

# make_case <name>: a case directory with a fake curl, a home whose .env holds
# the credentials, a task record, and a worktree whose HEAD is on a
# remote-tracking ref so the ready gate accepts it. Echoes the case directory.
make_case() {
  local d="$TMP_ROOT/$1"
  mkdir -p "$d/fakebin" "$d/routes" "$d/state" "$d/home/data" "$d/home/config"
  printf 'BITBUCKET_EMAIL=%s\nBITBUCKET_API_TOKEN=%s\n' "$EMAIL" "$TOKEN" > "$d/home/.env"
  cp "$ROOT/.tasks.toml" "$d/home/.tasks.toml"
  printf '%s\n' '## In flight' '' '## Queued' '' '## Done' > "$d/home/data/backlog.md"
  fm_git_init_commit "$d/wt"
  git -C "$d/wt" update-ref refs/remotes/origin/main "$(git -C "$d/wt" rev-parse HEAD)"
  fm_write_meta "$d/state/task-b1.meta" \
    "window=fm-task-b1" "worktree=$d/wt" "project=$d/project" "kind=ship" "mode=no-mistakes"
  : > "$d/curl.log"
  write_curl_mock "$d"
  ln -sf "$REAL_JQ" "$d/fakebin/jq"
  printf '%s\n' "$d"
}

# The fake curl. A request is answered from routes/<key>, where the key is the
# method and the URL below the repositories/ prefix with every "/", "?", "=",
# and "&" turned into "_". The file's first line is the HTTP status and the
# rest is the body. A numbered routes/<key>.<n> answers the n-th call instead,
# and once a merge POST has been answered routes/<key>.merged takes over, so
# one case can move a head or a state. Status 000 is a transport failure.
write_curl_mock() {
  cat > "$1/fakebin/curl" <<'SH'
#!/usr/bin/env bash
out='' fmt='' method=GET url='' data='' auth=none header=''
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
for arg in "$url" "$out" "$fmt"; do
  case "$arg" in *"$FM_TEST_BB_TOKEN"*) echo "token on argv" >> "$FM_TEST_BB_LOG" ;; esac
done
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

route_key() {  # <method> <path below repositories/>
  printf '%s %s' "$1" "$2" | tr '/?=& ' '_____'
}

route() {  # <case> <method> <path> <code> <body> [<suffix>]
  local file
  file="$1/routes/$(route_key "$2" "$3")${6:+.$6}"
  printf '%s\n%s\n' "$4" "$5" > "$file"
}

pr_json() {  # <state> <short-head> [<draft>]
  printf '{"type":"pullrequest","id":%s,"state":"%s","draft":%s,"source":{"commit":{"hash":"%s"}}}' \
    "$PR_ID" "$1" "${3:-false}" "$2"
}

route_pr() {  # <case> <state> <short-head> [<draft>] [<suffix>]
  route "$1" GET "$WS/$REPO/pullrequests/$PR_ID" 200 "$(pr_json "$2" "$3" "${4:-false}")" "${5:-}"
}

route_commit() {  # <case> <short> <full>
  route "$1" GET "$WS/$REPO/commit/$2" 200 "{\"hash\":\"$3\",\"type\":\"commit\"}"
}

route_statuses() {  # <case> <full-sha> [<STATE>:<key> ...]
  local d=$1 sha=$2 spec values=''
  shift 2
  for spec in "$@"; do
    values="${values:+$values,}{\"type\":\"build\",\"state\":\"${spec%%:*}\",\"key\":\"${spec#*:}\"}"
  done
  route "$d" GET "$WS/$REPO/commit/$sha/statuses?pagelen=100" 200 \
    "{\"values\":[$values],\"pagelen\":100,\"size\":$#,\"next\":null}"
}

# A pull request that satisfies every pre-merge condition and reads MERGED
# once the merge call has been answered.
route_green_pr() {  # <case>
  route_pr "$1" OPEN "$SHORT"
  route_pr "$1" MERGED "$SHORT" false merged
  route_commit "$1" "$SHORT" "$HEAD_SHA"
  route_statuses "$1" "$HEAD_SHA" SUCCESSFUL:pipeline SUCCESSFUL:lint
  route "$1" POST "$WS/$REPO/pullrequests/$PR_ID/merge" 200 "$(pr_json MERGED "$SHORT")"
}

with_case_env() {  # <case> <command...>
  local d=$1
  shift
  FM_TEST_BB_ROUTES="$d/routes" FM_TEST_BB_LOG="$d/curl.log" \
    FM_TEST_BB_EMAIL="$EMAIL" FM_TEST_BB_TOKEN="$TOKEN" \
    FM_HOME="$d/home" PATH="$d/fakebin:$PATH" "$@"
}

run_bb() {  # <case> <args...>
  local d=$1
  shift
  with_case_env "$d" env -u BITBUCKET_EMAIL -u BITBUCKET_API_TOKEN "$BB" "$@"
}

run_pr_merge() {  # <case> <args...>
  local d=$1
  shift
  with_case_env "$d" env -u BITBUCKET_EMAIL -u BITBUCKET_API_TOKEN \
    FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$d/state" HOME="$d/user-home" \
    "$PR_MERGE" "$@"
}

run_pr_check() {  # <case> <args...>
  local d=$1
  shift
  with_case_env "$d" env -u BITBUCKET_EMAIL -u BITBUCKET_API_TOKEN \
    FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$d/state" HOME="$d/user-home" \
    "$PR_CHECK" "$@"
}

# The token must never surface anywhere a test can see.
assert_token_absent() {  # <case> <label>
  local d=$1 label=$2 hit
  hit=$(grep -rlF -- "$TOKEN" "$d" --exclude=.env 2>/dev/null | grep -v '/home/.env$' || true)
  [ -z "$hit" ] || fail "$label: the token appeared in $hit"
  ! grep -q 'token on argv' "$d/curl.log" || fail "$label: the token reached curl's argv"
}

test_url_parse() {
  fm_pr_url_parse "$URL" || fail "parse: a canonical Bitbucket pull request URL was refused"
  assert_equals bitbucket "$FM_PR_PROVIDER" "parse: provider"
  assert_equals bitbucket.org "$FM_PR_HOST" "parse: host"
  assert_equals "$WS/$REPO" "$FM_PR_PATH" "parse: workspace/repository path"
  assert_equals "$PR_ID" "$FM_PR_NUMBER" "parse: number"
  assert_equals "$URL" "$FM_PR_URL" "parse: the URL is kept as given"
  local bad
  for bad in \
    "http://bitbucket.org/$WS/$REPO/pull-requests/5" \
    "https://bitbucket.org/$WS/$REPO/pull-requests/5/" \
    "https://bitbucket.org/$WS/$REPO/pull-requests/0" \
    "https://bitbucket.org/$WS/$REPO/pull-requests/05" \
    "https://bitbucket.org/$WS/$REPO/pull-requests/5/diff" \
    "https://bitbucket.org/$WS/extra/$REPO/pull-requests/5" \
    "https://bitbucket.org/$WS/../pull-requests/5" \
    "https://bitbucket.org/-$WS/$REPO/pull-requests/5" \
    "https://bitbucket.org/$WS/$REPO/pull/5" \
    "https://bitbucket.org/$WS/$REPO/-/merge_requests/5" \
    "https://bitbucket.org/c/$REPO/+/5" \
    "https://www.bitbucket.org/$WS/$REPO/pull-requests/5"; do
    ! fm_pr_url_parse "$bad" || fail "parse: accepted $bad as $FM_PR_PROVIDER"
  done
  fm_pr_url_parse https://github.com/o/r/pull/3 && [ "$FM_PR_PROVIDER" = github ] \
    || fail "parse: a GitHub URL no longer parses as github"
  fm_pr_url_parse https://gitlab.example/g/p/-/merge_requests/3 && [ "$FM_PR_PROVIDER" = gitlab ] \
    || fail "parse: a GitLab URL no longer parses as gitlab"
  pass "Bitbucket pull request URLs parse strictly to the bitbucket identity"
}

test_state_mapping() {
  local d out forge expected
  d=$(make_case state-mapping)
  for forge in OPEN:OPEN:false MERGED:MERGED:true DECLINED:CLOSED:false SUPERSEDED:CLOSED:false; do
    route_pr "$d" "${forge%%:*}" "$SHORT"
    out=$(run_bb "$d" state "$WS" "$REPO" "$PR_ID") || fail "state: ${forge%%:*} was not readable"
    expected=$(printf 'state=%s\nmerged=%s\nforge_state=%s' \
      "$(printf '%s' "$forge" | cut -d: -f2)" "${forge##*:}" "${forge%%:*}")
    assert_equals "$expected" "$out" "state: ${forge%%:*} mapping"
  done
  route_pr "$d" WEIRD "$SHORT"
  ! run_bb "$d" state "$WS" "$REPO" "$PR_ID" >/dev/null 2>&1 \
    || fail "state: an unrecognised state was accepted"
  grep -qF "GET https://api.bitbucket.org/2.0/repositories/$WS/$REPO/pullrequests/$PR_ID auth=ok" "$d/curl.log" \
    || fail "state: the read did not reach the pull request endpoint with the credentials"
  assert_token_absent "$d" state
  pass "Bitbucket pull request states map onto OPEN, MERGED, and CLOSED"
}

test_pr_read_expands_head() {
  local d out
  d=$(make_case pr-head)
  route_pr "$d" OPEN "$SHORT" true
  route_commit "$d" "$SHORT" "$HEAD_SHA"
  out=$(run_bb "$d" pr "$WS" "$REPO" "$PR_ID") || fail "pr: the read failed"
  assert_contains "$out" "head=$HEAD_SHA" "pr: the short head was not expanded"
  assert_contains "$out" "draft=true" "pr: the draft flag was not reported"
  route_commit "$d" "$SHORT" "$OTHER_SHA"
  ! run_bb "$d" pr "$WS" "$REPO" "$PR_ID" >/dev/null 2>&1 \
    || fail "pr: a full hash that does not extend the short one was accepted"
  pass "a Bitbucket pull request read expands its short head to the full commit"
}

test_statuses_paging() {
  local d out key next
  d=$(make_case statuses)
  next="https://api.bitbucket.org/2.0/repositories/$WS/$REPO/commit/$HEAD_SHA/statuses?page=2"
  route "$d" GET "$WS/$REPO/commit/$HEAD_SHA/statuses?pagelen=100" 200 \
    "{\"values\":[{\"state\":\"SUCCESSFUL\",\"key\":\"one\"}],\"next\":\"$next\"}"
  route "$d" GET "$WS/$REPO/commit/$HEAD_SHA/statuses?page=2" 200 \
    '{"values":[{"state":"FAILED","key":"two\nforged"}]}'
  out=$(run_bb "$d" statuses "$WS" "$REPO" "$HEAD_SHA") || fail "statuses: the read failed"
  assert_equals "$(printf 'SUCCESSFUL\tone\nFAILED\ttwo forged')" "$out" "statuses: both pages, one line each"
  key=$(route_key GET "$WS/$REPO/commit/$HEAD_SHA/statuses?pagelen=100")
  printf '200\n{"values":[],"next":"https://evil.example/steal"}\n' > "$d/routes/$key"
  ! run_bb "$d" statuses "$WS" "$REPO" "$HEAD_SHA" >/dev/null 2>&1 \
    || fail "statuses: a next page on another host was followed"
  ! grep -q evil.example "$d/curl.log" || fail "statuses: the credentials were sent to another host"
  pass "Bitbucket build statuses are read across pages and never off the API host"
}

test_errors_are_named() {
  local d err
  d=$(make_case errors)
  route "$d" GET "$WS/$REPO/pullrequests/$PR_ID" 403 \
    '{"type":"error","error":{"message":"Your credentials lack one or more required privilege scopes.","detail":{"granted":["account"],"required":["pullrequest"]}}}'
  err=$(run_bb "$d" state "$WS" "$REPO" "$PR_ID" 2>&1 >/dev/null) && fail "errors: a 403 succeeded"
  assert_contains "$err" "HTTP 403" "errors: the 403 status"
  assert_contains "$err" "required scope(s): pullrequest" "errors: the missing scope"
  route "$d" GET "$WS/$REPO/pullrequests/$PR_ID" 401 ''
  err=$(run_bb "$d" state "$WS" "$REPO" "$PR_ID" 2>&1 >/dev/null) && fail "errors: a 401 succeeded"
  assert_contains "$err" "BITBUCKET_EMAIL and BITBUCKET_API_TOKEN" "errors: the 401 names both variables"
  route "$d" GET "$WS/$REPO/pullrequests/$PR_ID" 000 ''
  err=$(run_bb "$d" state "$WS" "$REPO" "$PR_ID" 2>&1 >/dev/null) && fail "errors: a transport failure succeeded"
  assert_contains "$err" "could not reach Bitbucket" "errors: the transport failure"
  printf 'BITBUCKET_EMAIL=%s\n' "$EMAIL" > "$d/home/.env"
  err=$(run_bb "$d" credentials 2>&1) && fail "errors: a missing token passed the credential check"
  assert_contains "$err" "needs BITBUCKET_API_TOKEN" "errors: the missing variable is named"
  assert_not_contains "$err" "BITBUCKET_EMAIL," "errors: only the missing variable is named"
  err=$(with_case_env "$d" env BITBUCKET_API_TOKEN="$TOKEN" "$BB" credentials 2>&1) \
    || fail "errors: an environment token did not complete the .env credentials ($err)"
  assert_token_absent "$d" errors
  pass "Bitbucket failures name the status, missing scope, or missing variable"
}

test_record_reader() {
  local d
  d=$(make_case record-reader)
  route_pr "$d" DECLINED "$SHORT"
  # with_case_env runs the function in this shell, so its result is readable here.
  with_case_env "$d" fm_pr_bitbucket_read_record "$WS/$REPO" "$PR_ID" \
    || fail "reader: the record was not readable"
  assert_equals CLOSED "$FM_PR_RECORD_STATE" "reader: DECLINED reads as CLOSED"
  assert_equals false "$FM_PR_RECORD_MERGED" "reader: a declined pull request is not merged"
  route "$d" GET "$WS/$REPO/pullrequests/$PR_ID" 500 'boom'
  ! with_case_env "$d" fm_pr_bitbucket_read_record "$WS/$REPO" "$PR_ID" \
    || fail "reader: a failed read was accepted"
  pass "the shared record reader reads a Bitbucket pull request's state"
}

test_merge_poll() {
  local d out
  d=$(make_case poll)
  route_pr "$d" OPEN "$SHORT"
  out=$(with_case_env "$d" bash "$POLL" --validated bitbucket "$URL" bitbucket.org "$WS/$REPO" "$PR_ID")
  assert_equals '' "$out" "poll: an open pull request woke the poll"
  route_pr "$d" MERGED "$SHORT"
  out=$(with_case_env "$d" bash "$POLL" --validated bitbucket "$URL" bitbucket.org "$WS/$REPO" "$PR_ID")
  assert_equals merged "$out" "poll: a merged pull request did not wake the poll"
  out=$(with_case_env "$d" bash "$POLL" --validated bitbucket "$URL" bitbucket.org "$WS/other" "$PR_ID")
  assert_equals '' "$out" "poll: a path that does not rebuild the URL was read"
  out=$(with_case_env "$d" bash "$POLL" --validated bitbucket "$URL" evil.example "$WS/$REPO" "$PR_ID")
  assert_equals '' "$out" "poll: another host was read"
  route "$d" GET "$WS/$REPO/pullrequests/$PR_ID" 403 '{"type":"error","error":{"message":"no"}}'
  out=$(with_case_env "$d" bash "$POLL" --validated bitbucket "$URL" bitbucket.org "$WS/$REPO" "$PR_ID")
  assert_equals '' "$out" "poll: a refused read woke the poll"
  rm -f "$d/home/.env"
  route_pr "$d" MERGED "$SHORT"
  out=$(with_case_env "$d" env -u BITBUCKET_EMAIL -u BITBUCKET_API_TOKEN \
    bash "$POLL" --validated bitbucket "$URL" bitbucket.org "$WS/$REPO" "$PR_ID")
  assert_equals '' "$out" "poll: a read without credentials woke the poll"
  pass "the Bitbucket merge poll wakes only on an exact merged read"
}

test_arming_records_pr_without_head_and_refuses_drafts() {
  local d out rc
  d=$(make_case arm)
  route_pr "$d" OPEN "$SHORT"
  route_commit "$d" "$SHORT" "$HEAD_SHA"
  rc=0
  out=$(run_pr_check "$d" task-b1 "$URL" 2>&1) || rc=$?
  expect_code 0 "$rc" "arm: arming a Bitbucket pull request failed: $out"
  assert_grep "pr=$URL" "$d/state/task-b1.meta" "arm: pr= was not recorded: $out"
  assert_no_grep "pr_head=" "$d/state/task-b1.meta" "arm: pr_head= was recorded"
  assert_present "$d/state/task-b1.check.sh" "arm: no merge poll was armed"
  assert_equals "$(printf 'bitbucket\n%s\nbitbucket.org\n%s\n%s' "$URL" "$WS/$REPO" "$PR_ID")" \
    "$(cat "$d/state/task-b1.pr-poll")" "arm: the poll sidecar identity"

  d=$(make_case arm-draft)
  route_pr "$d" OPEN "$SHORT" true
  route_commit "$d" "$SHORT" "$HEAD_SHA"
  rc=0
  out=$(run_pr_check "$d" task-b1 "$URL" 2>&1) || rc=$?
  expect_code 1 "$rc" "arm-draft: a draft pull request was armed"
  assert_contains "$out" "is a draft pull request" "arm-draft: the refusal did not name the draft"
  assert_no_grep 'pr=https' "$d/state/task-b1.meta" "arm-draft: pr= was recorded for a draft"

  d=$(make_case arm-draft-commit-fails)
  route_pr "$d" OPEN "$SHORT" true
  route "$d" GET "$WS/$REPO/commit/$SHORT" 500 '{"type":"error","error":{"message":"unavailable"}}'
  rc=0
  out=$(run_pr_check "$d" task-b1 "$URL" 2>&1) || rc=$?
  expect_code 1 "$rc" "arm-draft-commit-fails: a draft was armed when the commit read failed"
  assert_contains "$out" "is a draft pull request" "arm-draft-commit-fails: the refusal did not name the draft"
  assert_no_grep 'pr=https' "$d/state/task-b1.meta" "arm-draft-commit-fails: pr= was recorded for a draft"
  assert_absent "$d/state/task-b1.check.sh" "arm-draft-commit-fails: a poll was armed"

  d=$(make_case arm-no-creds)
  rm -f "$d/home/.env"
  rc=0
  out=$(run_pr_check "$d" task-b1 "$URL" 2>&1) || rc=$?
  expect_code 1 "$rc" "arm-no-creds: a watch was armed without credentials"
  assert_contains "$out" "BITBUCKET_EMAIL and BITBUCKET_API_TOKEN" "arm-no-creds: the missing variables were not named"
  assert_absent "$d/state/task-b1.check.sh" "arm-no-creds: a poll was armed"
  [ ! -s "$d/curl.log" ] || fail "arm-no-creds: a request was made without credentials"
  pass "arming a Bitbucket pull request records the URL without a head, refuses drafts, and needs credentials"
}

merge_posts() {  # <case>
  grep -c "^POST .*/pullrequests/$PR_ID/merge " "$1/curl.log" || true
}

test_green_merge_squashes_and_reads_back() {
  local d out rc
  d=$(make_case merge-green)
  route_green_pr "$d"
  rc=0
  out=$(run_pr_merge "$d" task-b1 "$URL" 2>&1) || rc=$?
  expect_code 0 "$rc" "merge-green: the merge failed: $out"
  assert_equals 1 "$(merge_posts "$d")" "merge-green: expected exactly one merge call"
  assert_grep '"merge_strategy":"squash"' "$d/curl.log" "merge-green: squash is not the default"
  assert_grep '"close_source_branch":false' "$d/curl.log" "merge-green: the source branch was not kept"
  assert_contains "$out" "verified: $URL is merged (state=MERGED)" "merge-green: the read-back was not reported"
  assert_contains "$out" "2 successful build status(es) at head $HEAD_SHA" "merge-green: the verified head"
  assert_grep "pr=$URL" "$d/state/task-b1.meta" "merge-green: pr= was not recorded"
  assert_present "$d/state/task-b1.pr-poll-merge-notified" "merge-green: no landed outcome was recorded"
  assert_token_absent "$d" merge-green

  d=$(make_case merge-commit-strategy)
  route_green_pr "$d"
  run_pr_merge "$d" task-b1 "$URL" -- --merge >/dev/null 2>&1 \
    || fail "merge-commit-strategy: --merge failed"
  assert_grep '"merge_strategy":"merge_commit"' "$d/curl.log" "merge-commit-strategy: --merge did not select merge_commit"
  pass "a green Bitbucket pull request merges with squash by default and is read back merged"
}

test_red_or_pending_statuses_refuse() {
  local d out rc spec
  for spec in FAILED INPROGRESS STOPPED; do
    d=$(make_case "merge-$spec")
    route_green_pr "$d"
    route_statuses "$d" "$HEAD_SHA" SUCCESSFUL:lint "$spec:pipeline"
    rc=0
    out=$(run_pr_merge "$d" task-b1 "$URL" 2>&1) || rc=$?
    [ "$rc" -ne 0 ] || fail "merge-$spec: a $spec status merged"
    assert_contains "$out" "build status \"pipeline\" is $spec at head $HEAD_SHA, not SUCCESSFUL" \
      "merge-$spec: the status was not named"
    assert_equals 0 "$(merge_posts "$d")" "merge-$spec: the merge was attempted"
    assert_absent "$d/state/task-b1.pr-poll-merge-notified" "merge-$spec: an outcome was recorded"
  done

  d=$(make_case merge-draft-declined)
  route_green_pr "$d"
  route_pr "$d" DECLINED "$SHORT" true
  rc=0
  out=$(run_pr_merge "$d" task-b1 "$URL" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "merge-draft-declined: merged"
  assert_contains "$out" 'state is "DECLINED", not OPEN' "merge-draft-declined: state not reported"
  assert_contains "$out" 'draft is "true", not false' "merge-draft-declined: draft not reported"
  assert_equals 0 "$(merge_posts "$d")" "merge-draft-declined: the merge was attempted"

  d=$(make_case merge-no-statuses)
  route_green_pr "$d"
  route_statuses "$d" "$HEAD_SHA"
  out=$(run_pr_merge "$d" task-b1 "$URL" 2>&1) || fail "merge-no-statuses: refused: $out"
  assert_contains "$out" "no build status has reported at head $HEAD_SHA" "merge-no-statuses: no notice"
  pass "any build status other than SUCCESSFUL refuses a Bitbucket merge before it is attempted"
}

test_head_drift_refuses() {
  local d out rc
  d=$(make_case merge-head-drift)
  route_green_pr "$d"
  # The first read records the pull request and the second verifies it, both
  # at SHORT; the third, right before the merge call, sees a push.
  route_pr "$d" OPEN "$OTHER_SHORT" false 3
  route_commit "$d" "$OTHER_SHORT" "$OTHER_SHA"
  rc=0
  out=$(run_pr_merge "$d" task-b1 "$URL" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "merge-head-drift: merged after the head moved"
  assert_contains "$out" "moved from the verified $HEAD_SHA to $OTHER_SHA" "merge-head-drift: the drift was not named"
  assert_equals 0 "$(merge_posts "$d")" "merge-head-drift: the merge was attempted"
  assert_absent "$d/state/task-b1.pr-poll-merge-notified" "merge-head-drift: an outcome was recorded"
  pass "a head that moves before the Bitbucket merge call refuses the merge"
}

test_forge_refusal_is_surfaced() {
  local d out rc
  d=$(make_case merge-refused)
  route_green_pr "$d"
  route "$d" POST "$WS/$REPO/pullrequests/$PR_ID/merge" 400 \
    '{"type":"error","error":{"message":"You can'"'"'t merge until you have at least 2 approvals."}}'
  route_pr "$d" OPEN "$SHORT" false merged
  rc=0
  out=$(run_pr_merge "$d" task-b1 "$URL" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "merge-refused: a refused merge exited 0"
  assert_contains "$out" "HTTP 400" "merge-refused: the status was not surfaced"
  assert_contains "$out" "at least 2 approvals" "merge-refused: Bitbucket's reason was not surfaced"
  assert_contains "$out" "Bitbucket did not merge $URL; nothing was reported as landed" "merge-refused: verdict"
  assert_absent "$d/state/task-b1.pr-poll-merge-notified" "merge-refused: an outcome was recorded"
  assert_present "$d/state/task-b1.check.sh" "merge-refused: the poll was not left armed"
  pass "a Bitbucket merge refusal is surfaced in its own words and never reported landed"
}

test_unconfirmed_merge_leaves_poll_armed() {
  local d out rc
  d=$(make_case merge-unconfirmed)
  route_green_pr "$d"
  route "$d" POST "$WS/$REPO/pullrequests/$PR_ID/merge" 202 ''
  route_pr "$d" OPEN "$SHORT" false merged
  rc=0
  out=$(run_pr_merge "$d" task-b1 "$URL" 2>&1) || rc=$?
  expect_code 1 "$rc" "merge-unconfirmed: an accepted merge that is not yet landed exited 0: $out"
  assert_contains "$out" "not yet landed" "merge-unconfirmed: the unconfirmed state was not reported"
  assert_contains "$out" "HTTP 202" "merge-unconfirmed: the async accept was not named"
  assert_absent "$d/state/task-b1.pr-poll-merge-notified" "merge-unconfirmed: an outcome was recorded"
  assert_present "$d/state/task-b1.check.sh" "merge-unconfirmed: the poll was not left armed"

  d=$(make_case merge-readback-open)
  route_green_pr "$d"
  route_pr "$d" OPEN "$SHORT" false merged
  rc=0
  out=$(run_pr_merge "$d" task-b1 "$URL" 2>&1) || rc=$?
  expect_code 1 "$rc" "merge-readback-open: a merge that still reads open exited 0: $out"
  assert_contains "$out" "not yet landed" "merge-readback-open: the open read-back was not reported"
  assert_absent "$d/state/task-b1.pr-poll-merge-notified" "merge-readback-open: an outcome was recorded"
  assert_present "$d/state/task-b1.check.sh" "merge-readback-open: the poll was not left armed"
  pass "an accepted Bitbucket merge that is not yet landed exits non-success and leaves the poll armed"
}

test_away_merge_is_refused() {
  local d out rc
  d=$(make_case merge-away)
  route_green_pr "$d"
  FM_HOME="$d/home" FM_STATE_OVERRIDE="$d/state" \
    "$ROOT/bin/fm-afk-contract.sh" enter --words 'merge when green' >/dev/null \
    || fail "merge-away: could not record away posture"
  rc=0
  out=$(run_pr_merge "$d" task-b1 "$URL" 2>&1) || rc=$?
  expect_code 2 "$rc" "merge-away: an away Bitbucket merge was not refused: $out"
  assert_contains "$out" "attended-only" "merge-away: the refusal did not name attended-only"
  assert_contains "$out" "away-posture record" "merge-away: the refusal did not name the away record"
  assert_equals 0 "$(merge_posts "$d")" "merge-away: a merge POST was made"
  assert_absent "$d/state/task-b1.pr-poll-merge-notified" "merge-away: an outcome was recorded"
  pass "a Bitbucket merge is refused before the POST while an away record exists"
}

test_merge_arguments_and_prerequisites() {
  local d out rc
  d=$(make_case merge-args)
  route_green_pr "$d"
  rc=0
  out=$(run_pr_merge "$d" task-b1 "$URL" -- --rebase 2>&1) || rc=$?
  expect_code 2 "$rc" "merge-args: an unknown argument was accepted"
  assert_contains "$out" "accepts only --squash (the default) or --merge" "merge-args: the refusal"
  rc=0
  out=$(run_pr_merge "$d" task-b1 "$URL" --allow-red pipeline 2>&1) || rc=$?
  expect_code 2 "$rc" "merge-args: --allow-red was accepted"
  assert_contains "$out" "do not apply to Bitbucket" "merge-args: the --allow-red refusal"
  rm -f "$d/home/.env"
  rc=0
  out=$(run_pr_merge "$d" task-b1 "$URL" 2>&1) || rc=$?
  expect_code 1 "$rc" "merge-args: a merge ran without credentials"
  assert_contains "$out" "requires its credentials" "merge-args: the credential refusal"
  [ ! -s "$d/curl.log" ] || fail "merge-args: a request was made"
  assert_no_grep 'pr=https' "$d/state/task-b1.meta" "merge-args: pr= was recorded"
  pass "a Bitbucket merge refuses foreign arguments and missing credentials before recording anything"
}

test_url_parse
test_state_mapping
test_pr_read_expands_head
test_statuses_paging
test_errors_are_named
test_record_reader
test_merge_poll
test_arming_records_pr_without_head_and_refuses_drafts
test_green_merge_squashes_and_reads_back
test_red_or_pending_statuses_refuse
test_head_drift_refuses
test_forge_refusal_is_surfaced
test_unconfirmed_merge_leaves_poll_armed
test_away_merge_is_refused
test_merge_arguments_and_prerequisites
