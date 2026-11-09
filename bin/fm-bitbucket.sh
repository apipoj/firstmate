#!/usr/bin/env bash
# Bitbucket Cloud pull request access for firstmate's PR tooling, through the
# REST API 2.0 at https://api.bitbucket.org/2.0. Bitbucket has no standard CLI
# the way GitHub has gh and GitLab has glab, so this script is the single owner
# of the Bitbucket HTTP shape, its credentials, its state mapping, and how its
# errors read. bin/fm-pr-lib.sh, bin/fm-pr-poll.sh, bin/fm-pr-check.sh,
# bin/fm-pr-merge.sh, and bin/fm-crew-state.sh all reach Bitbucket only through
# it.
#
# Credentials: an Atlassian API token used as HTTP basic auth, BITBUCKET_EMAIL
# as the user and BITBUCKET_API_TOKEN as the password. Each is read from the
# environment first and otherwise from the home's gitignored $FM_HOME/.env
# through bin/fm-env-lib.sh, so the environment wins as it does for the Relay
# and mail planes. The pair reaches curl as an Authorization header read from a
# file descriptor, never on argv, and nothing prints, logs, or writes it. A
# missing variable is named. A 403 names the scopes Bitbucket reports the token
# lacks; reading needs read:pullrequest and read:repository, and merging also
# needs write:pullrequest.
#
# Usage:
#   fm-bitbucket.sh credentials
#     Exit 0 when both variables resolve; otherwise name the missing one.
#     Makes no network call.
#   fm-bitbucket.sh state <workspace> <repo> <id>
#     One read. Prints state=, merged=, and forge_state= lines.
#   fm-bitbucket.sh pr <workspace> <repo> <id>
#     The state lines plus draft= (true, false, or empty when Bitbucket did not
#     report a boolean), printed before head=, the source commit expanded from
#     the short hash the pull request carries. A failed expansion exits 1 after
#     that draft line and does not print head=.
#   fm-bitbucket.sh statuses <workspace> <repo> <full-sha>
#     Every build status reported at that commit, all pages, one
#     "<STATE><tab><key>" line each; no line when none has reported.
#   fm-bitbucket.sh merge <workspace> <repo> <id> <strategy>
#     One POST to the pull request's merge endpoint with the given
#     merge_strategy and close_source_branch false. Prints http=<code> on a 2xx
#     answer: 200 is a completed merge and 202 an accepted one Bitbucket is
#     still running, so a caller reads the state back either way. Any other
#     answer, including a branch-restriction or merge-check refusal, prints
#     Bitbucket's own message and exits 1.
#
# State mapping: OPEN is OPEN; MERGED is MERGED with merged=true; DECLINED and
# SUPERSEDED are CLOSED, because both end the pull request without landing it.
# forge_state keeps Bitbucket's own word. Any other state is an unreadable
# answer and exits 1 rather than guessing.
#
# Exit status: 0 on success, 1 on a failed or unreadable forge answer or
# missing credentials (with the reason on stderr), 2 on a usage error.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

# shellcheck source=bin/fm-env-lib.sh
. "$SCRIPT_DIR/fm-env-lib.sh"

BB_API=https://api.bitbucket.org/2.0
BB_TIMEOUT=20
BB_MAX_STATUS_PAGES=20
LC_ALL=C
export LC_ALL

usage() {
  sed -n '2,/^set -eu$/s/^# \{0,1\}//p' "$0" >&2
  exit 2
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

valid_slug() {
  case "${1-}" in
    ''|.|..|-*|*[!A-Za-z0-9_.-]*) return 1 ;;
  esac
  [ "${#1}" -le 100 ]
}

valid_id() {
  case "${1-}" in
    [1-9]*) ;;
    *) return 1 ;;
  esac
  case "$1" in
    *[!0-9]*) return 1 ;;
  esac
  [ "${#1}" -le 18 ]
}

valid_full_sha() {
  [[ "${1-}" =~ ^[0-9a-f]{40}$|^[0-9a-f]{64}$ ]]
}

# The credentials are copied into private shell variables and unexported, so
# no child process inherits them through its environment either.
BB_EMAIL=
BB_TOKEN=
load_credentials() {
  local email=${BITBUCKET_EMAIL:-} token=${BITBUCKET_API_TOKEN:-}
  unset BITBUCKET_EMAIL BITBUCKET_API_TOKEN
  [ -n "$email" ] || email=$(fmx_env_get BITBUCKET_EMAIL "$FM_HOME/.env")
  [ -n "$token" ] || token=$(fmx_env_get BITBUCKET_API_TOKEN "$FM_HOME/.env")
  if [ -z "$email" ] && [ -z "$token" ]; then
    die "Bitbucket access needs BITBUCKET_EMAIL and BITBUCKET_API_TOKEN, and neither is set in the environment or $FM_HOME/.env"
  fi
  [ -n "$email" ] || die "Bitbucket access needs BITBUCKET_EMAIL, which is not set in the environment or $FM_HOME/.env"
  [ -n "$token" ] || die "Bitbucket access needs BITBUCKET_API_TOKEN, which is not set in the environment or $FM_HOME/.env"
  BB_EMAIL=$email
  BB_TOKEN=$token
}

require_tools() {
  local tool missing=''
  for tool in curl jq base64; do
    command -v "$tool" >/dev/null 2>&1 || missing="${missing:+$missing, }$tool"
  done
  [ -z "$missing" ] || die "Bitbucket access requires $missing on PATH"
}

BB_WORK=
cleanup() {
  [ -z "$BB_WORK" ] || rm -rf -- "$BB_WORK"
}
trap cleanup EXIT

# The basic-auth header is built in a pipeline and handed to curl on fd 3, so
# the token never appears on any command line.
auth_header() {
  printf 'Authorization: Basic %s\n' \
    "$(printf '%s:%s' "$BB_EMAIL" "$BB_TOKEN" | base64 | tr -d '\n')"
}

BB_HTTP=
BB_BODY=
# request <method> <url> [<json-body-file>]: sets BB_HTTP to the status code,
# or 000 when no answer arrived, and leaves the answer in $BB_BODY.
request() {
  local method=$1 url=$2 data=${3-}
  local -a extra=()
  [ -z "$data" ] || extra=(-H 'Content-Type: application/json' --data-binary "@$data")
  BB_BODY="$BB_WORK/body"
  : > "$BB_BODY"
  BB_HTTP=$(curl -sS --max-time "$BB_TIMEOUT" -o "$BB_BODY" -w '%{http_code}' \
    -X "$method" -H 'Accept: application/json' -H @/dev/fd/3 \
    "${extra[@]+"${extra[@]}"}" "$url" \
    3< <(auth_header) 2> "$BB_WORK/curl.err") || BB_HTTP=000
  case "$BB_HTTP" in
    [0-9][0-9][0-9]) ;;
    *) BB_HTTP=000 ;;
  esac
}

# One line of untrusted forge text, with control characters removed and the
# length bounded, so an answer cannot forge extra output lines.
one_line() {
  tr '\n\r\t' '   ' | tr -d '\000-\037\177' | cut -c 1-300
}

# fail_request <what>: report a non-2xx or absent answer in Bitbucket's own
# words where it gave any, then exit 1.
fail_request() {
  local what=$1 message
  if [ "$BB_HTTP" = 000 ]; then
    message=$(one_line < "$BB_WORK/curl.err")
    die "could not reach Bitbucket to $what${message:+: $message}"
  fi
  message=$(jq -r '
    if type == "object" and (.error | type) == "object" then
      [ (.error.message // empty | tostring),
        (if (.error.detail | type) == "string" then .error.detail
         elif (.error.detail.required | type) == "array"
         then "the token lacks required scope(s): " + (.error.detail.required | map(tostring) | join(", "))
         else empty end)
      ] | map(select(. != "")) | join("; ")
    else empty end' "$BB_BODY" 2>/dev/null | one_line) || message=
  [ -n "$message" ] || message=$(one_line < "$BB_BODY")
  case "$BB_HTTP" in
    401)
      die "Bitbucket rejected the credentials (HTTP 401) while trying to $what; check BITBUCKET_EMAIL and BITBUCKET_API_TOKEN${message:+: $message}"
      ;;
    *)
      die "Bitbucket refused to $what (HTTP $BB_HTTP)${message:+: $message}"
      ;;
  esac
}

repo_api() {
  printf '%s/repositories/%s/%s' "$BB_API" "$1" "$2"
}

# Reads one pull request and prints the state lines. Sets PR_SHORT_HEAD and
# PR_DRAFT for the pr subcommand.
PR_SHORT_HEAD=
PR_DRAFT=
read_pull_request() {
  local workspace=$1 repo=$2 id=$3 fields forge_state state merged=false
  request GET "$(repo_api "$workspace" "$repo")/pullrequests/$id"
  [ "$BB_HTTP" = 200 ] || fail_request "read pull request $workspace/$repo#$id"
  if ! fields=$(jq -r --argjson id "$id" '
      if type == "object" and .id == $id and (.state | type) == "string"
        and (.state | test("^[A-Z]+$"))
      then
        "forge_state=" + .state,
        "short_head=" + (.source.commit.hash // "" | tostring),
        "draft=" + (if (.draft | type) == "boolean" then (.draft | tostring) else "" end)
      else error("not this pull request")
      end' "$BB_BODY" 2>/dev/null); then
    die "Bitbucket answered with an unreadable pull request record for $workspace/$repo#$id"
  fi
  forge_state=$(printf '%s\n' "$fields" | sed -n 's/^forge_state=//p')
  PR_SHORT_HEAD=$(printf '%s\n' "$fields" | sed -n 's/^short_head=//p')
  PR_DRAFT=$(printf '%s\n' "$fields" | sed -n 's/^draft=//p')
  case "$forge_state" in
    OPEN) state=OPEN ;;
    MERGED) state=MERGED; merged=true ;;
    DECLINED|SUPERSEDED) state=CLOSED ;;
    *) die "Bitbucket reported pull request $workspace/$repo#$id in unrecognised state $forge_state" ;;
  esac
  printf 'state=%s\nmerged=%s\nforge_state=%s\n' "$state" "$merged" "$forge_state"
}

# A pull request names its source commit by a short hash; the commit endpoint
# answers with the full one, which must extend the short hash it was asked for.
expand_commit() {
  local workspace=$1 repo=$2 short=$3 full
  [[ "$short" =~ ^[0-9a-f]{7,64}$ ]] \
    || die "Bitbucket reported no readable source commit for this pull request"
  request GET "$(repo_api "$workspace" "$repo")/commit/$short"
  [ "$BB_HTTP" = 200 ] || fail_request "read commit $short in $workspace/$repo"
  full=$(jq -r 'if type == "object" and (.hash | type) == "string" then .hash else empty end' \
    "$BB_BODY" 2>/dev/null) || full=
  valid_full_sha "$full" && [ "${full#"$short"}" != "$full" ] \
    || die "Bitbucket answered commit $short with an unreadable full hash"
  printf '%s\n' "$full"
}

# Every page of build statuses at one commit. A next link is followed only on
# the API's own origin, so a doctored answer cannot send the credentials
# elsewhere, and an answer that keeps paging past the bound is refused rather
# than read as complete.
read_statuses() {
  local workspace=$1 repo=$2 sha=$3 url pages=0 lines next
  url="$(repo_api "$workspace" "$repo")/commit/$sha/statuses?pagelen=100"
  while [ -n "$url" ]; do
    pages=$((pages + 1))
    [ "$pages" -le "$BB_MAX_STATUS_PAGES" ] \
      || die "Bitbucket kept paging build statuses for $sha past $BB_MAX_STATUS_PAGES pages"
    request GET "$url"
    [ "$BB_HTTP" = 200 ] || fail_request "read build statuses for $sha in $workspace/$repo"
    if ! lines=$(jq -r '
        if type == "object" and (.values | type) == "array"
          and all(.values[]; type == "object" and (.state | type) == "string")
        then .values[]
          | (.state | gsub("[^A-Z_]"; "")) + "\t"
            + ((.key // .name // "") | tostring | gsub("[[:cntrl:]]"; " "))
        else error("unreadable statuses")
        end' "$BB_BODY" 2>/dev/null); then
      die "Bitbucket answered with unreadable build statuses for $sha"
    fi
    [ -z "$lines" ] || printf '%s\n' "$lines"
    next=$(jq -r 'if (.next | type) == "string" then .next else "" end' "$BB_BODY" 2>/dev/null) || next=
    case "$next" in
      '') url= ;;
      "$BB_API/"*) url=$next ;;
      *) die "Bitbucket answered build statuses with a next page outside $BB_API" ;;
    esac
  done
}

merge_pull_request() {
  local workspace=$1 repo=$2 id=$3 strategy=$4 payload
  payload="$BB_WORK/merge.json"
  jq -cn --arg strategy "$strategy" \
    '{merge_strategy: $strategy, close_source_branch: false}' > "$payload"
  request POST "$(repo_api "$workspace" "$repo")/pullrequests/$id/merge" "$payload"
  case "$BB_HTTP" in
    200|202) printf 'http=%s\n' "$BB_HTTP" ;;
    *) fail_request "merge pull request $workspace/$repo#$id" ;;
  esac
}

[ "$#" -ge 1 ] || usage
COMMAND=$1
shift
case "$COMMAND" in
  -h|--help) usage ;;
  credentials)
    [ "$#" -eq 0 ] || usage
    load_credentials
    exit 0
    ;;
  state|pr)
    if ! { [ "$#" -eq 3 ] && valid_slug "$1" && valid_slug "$2" && valid_id "$3"; }; then usage; fi
    ;;
  statuses)
    if ! { [ "$#" -eq 3 ] && valid_slug "$1" && valid_slug "$2" && valid_full_sha "$3"; }; then usage; fi
    ;;
  merge)
    if ! { [ "$#" -eq 4 ] && valid_slug "$1" && valid_slug "$2" && valid_id "$3"; }; then usage; fi
    case "$4" in
      merge_commit|squash|fast_forward|squash_fast_forward|rebase_fast_forward|rebase_merge) ;;
      *) usage ;;
    esac
    ;;
  *) usage ;;
esac

require_tools
load_credentials
BB_WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-bitbucket.XXXXXX")
chmod 0700 "$BB_WORK"

case "$COMMAND" in
  state)
    read_pull_request "$1" "$2" "$3"
    ;;
  pr)
    read_pull_request "$1" "$2" "$3"
    printf 'draft=%s\n' "$PR_DRAFT"
    HEAD_FULL=$(expand_commit "$1" "$2" "$PR_SHORT_HEAD") || exit 1
    printf 'head=%s\n' "$HEAD_FULL"
    ;;
  statuses)
    read_statuses "$1" "$2" "$3"
    ;;
  merge)
    merge_pull_request "$1" "$2" "$3" "$4"
    ;;
esac
