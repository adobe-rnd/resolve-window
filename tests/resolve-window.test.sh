#! /usr/bin/env bash
#
# Tests for resolve-window.sh.
#
# Every case executes the REAL script - there is no reimplementation of its logic here,
# because a copy of the logic under test silently diverges from it and then proves
# nothing. The run history comes from page<N>.json fixtures via RUNS_FIXTURE_DIR, so no
# network call is made, and "now" is pinned with NOW_EPOCH so window arithmetic is exact.
#
# Usage: tests/resolve-window.test.sh
# Exit 0 when every case passes, 1 otherwise.
#
# `set -e` is deliberately NOT used: most cases assert on a non-zero exit code, and the
# harness has to survive them.

TESTS_DIR=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$TESTS_DIR/../resolve-window.sh"

if [ ! -f "$SCRIPT" ]; then
  echo "cannot find resolve-window.sh next to tests/" >&2
  exit 1
fi

# epoch seconds -> RFC 3339 UTC. GNU date first, BSD/macOS second, so the suite runs on
# a macOS runner and therefore actually exercises the script's own date fallback.
iso() {
  local e="$1" out
  if out=$(date -u -d "@$e" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null); then printf '%s\n' "$out"; return 0; fi
  if out=$(date -u -r "$e" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null); then printf '%s\n' "$out"; return 0; fi
  echo "no usable date(1) for epoch->ISO conversion" >&2
  exit 1
}

pass=0
fail=0
case_name=''

# A fixed "now" so every expected timestamp is arithmetic, not wall-clock.
NOW=1789000000
NOW_ISO=$(iso $NOW)

WM_EPOCH=$((NOW - 1200))                                    # 20 minutes ago
WM=$(iso $WM_EPOCH)
OLD_EPOCH=$((NOW - 30 * 3600))                              # 30 hours ago
OLD=$(iso $OLD_EPOCH)
NEWER_EPOCH=$((NOW - 600))                                  # 10 minutes ago
NEWER=$(iso $NEWER_EPOCH)
FUTURE_EPOCH=$((NOW + 900))                                 # 15 minutes ahead
FUTURE=$(iso $FUTURE_EPOCH)

WORKDIR=$(mktemp -d)

# --- harness ---------------------------------------------------------------

start() {
  case_name="$1"
}

ok() {
  pass=$((pass + 1))
  printf '    ok    %s\n' "$1"
}

bad() {
  fail=$((fail + 1))
  printf '    FAIL  %s\n         %s\n' "$1" "$2"
}

# run_script <fixture-dir> [VAR=VALUE ...]
# Sets RC, OUT (stdout) and ERR (stderr). Later VAR=VALUE pairs override the defaults.
#
# The defaults are exported in a subshell rather than passed via `env VAR=VAL bash ...`.
# That form looks equivalent but is not portable: some shells drop the assignments
# entirely, which makes every case fail on the first `${VAR:?}` guard instead of testing
# what it claims to test.
run_script() {
  local dir="$1"
  shift
  local errfile="$WORKDIR/stderr.current"
  OUT=$(
    export RUNS_FIXTURE_DIR="$dir"
    export NOW_EPOCH="$NOW"
    export REPOSITORY='acme/widgets'
    export WORKFLOW='track.yml'
    export BRANCH=''
    export EXCLUDE_RUN_ID=''
    export OVERLAP_SECONDS='60'
    export MAX_PAGES='10'
    export PER_PAGE='100'
    export WIDE_WINDOW_HOURS='6'
    export OVERRIDE_START_TIME=''
    export INITIAL_WINDOW=''
    export GITHUB_OUTPUT=''
    export GITHUB_TOKEN=''
    for kv in "$@"; do
      export "$kv"
    done
    bash "$SCRIPT" 2>"$errfile"
  )
  RC=$?
  ERR=$(cat "$errfile" 2>/dev/null)
}

# Read one emitted `name=value` line from stdout.
out_value() {
  printf '%s\n' "$OUT" | grep "^$1=" | head -1 | cut -d= -f2-
}

expect_eq() {
  local label="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then
    ok "$label"
  else
    bad "$label" "wanted '$want', got '$got'"
  fi
}

expect_output() {
  local name="$1" want="$2"
  expect_eq "$case_name: $name=$want" "$want" "$(out_value "$name")"
}

expect_rc() {
  local want="$1"
  expect_eq "$case_name: exit $want" "$want" "$RC"
}

expect_stderr_has() {
  local needle="$1"
  case "$ERR" in
    *"$needle"*) ok "$case_name: stderr mentions '$needle'" ;;
    *) bad "$case_name: stderr mentions '$needle'" "stderr was: $(printf '%s' "$ERR" | tr '\n' ' ' | cut -c1-200)" ;;
  esac
}

expect_stderr_lacks() {
  local needle="$1"
  case "$ERR" in
    *"$needle"*) bad "$case_name: stderr must not mention '$needle'" "stderr was: $(printf '%s' "$ERR" | tr '\n' ' ' | cut -c1-200)" ;;
    *) ok "$case_name: stderr does not mention '$needle'" ;;
  esac
}

# --- fixture builders ------------------------------------------------------

new_fixture_dir() {
  local d
  d=$(mktemp -d "$WORKDIR/fixture.XXXXXX")
  printf '%s\n' "$d"
}

# write_page <dir> <n> <runs-json-array>
write_page() {
  jq -nc --argjson runs "$3" '{workflow_runs: $runs}' > "$1/page$2.json"
}

# A page of `n` runs that can never match, to force pagination. `count == PER_PAGE`
# is what tells the script there may be more pages.
write_filler_page() {
  local dir="$1" n="$2" count="$3"
  jq -nc --argjson count "$count" --arg ts "$OLD" '
    {workflow_runs: [range(0; $count) | {
      id: (900000 + .),
      conclusion: "failure",
      head_branch: "main",
      created_at: $ts
    }]}' > "$dir/page$n.json"
}

run_entry() {
  # run_entry <id> <conclusion|null> <branch> <created_at>
  jq -nc --arg id "$1" --arg c "$2" --arg b "$3" --arg t "$4" '
    {
      id: ($id | tonumber),
      conclusion: (if $c == "null" then null else $c end),
      head_branch: $b,
      created_at: $t
    }'
}

echo "resolve-window.sh"
echo "  now=$NOW_ISO  watermark fixture=$WM"

# --- 1. the ordinary case --------------------------------------------------

start 'resolves the newest successful run on page 1'
D=$(new_fixture_dir)
write_page "$D" 1 "[$(run_entry 5 success main "$WM"), $(run_entry 4 failure main "$NEWER")]"
run_script "$D"
expect_rc 0
expect_output source 'last-success'
expect_output watermark "$WM"
expect_output from "$(iso $((WM_EPOCH - 60)))"
expect_output from-epoch "$((WM_EPOCH - 60))"
expect_output from-ms "$(((WM_EPOCH - 60) * 1000))"
expect_output to "$NOW_ISO"
expect_output to-ms "$((NOW * 1000))"
expect_output age-hours '0'
expect_output age-seconds '1200'
expect_output is-catchup 'false'
expect_output runs-scanned '2'
expect_output pages-scanned '1'

# --- 2. newest wins regardless of order within the page --------------------

start 'takes the newest success even when the page is out of order'
D=$(new_fixture_dir)
write_page "$D" 1 "[$(run_entry 1 success main "$OLD"), $(run_entry 2 success main "$WM"), $(run_entry 3 success main "$OLD")]"
run_script "$D"
expect_rc 0
expect_output watermark "$WM"

# --- 3. only successful runs count -----------------------------------------

start 'ignores failure, cancelled, skipped and in-progress runs'
D=$(new_fixture_dir)
write_page "$D" 1 "[$(run_entry 9 failure main "$NEWER"), $(run_entry 8 cancelled main "$NEWER"), $(run_entry 7 skipped main "$NEWER"), $(run_entry 6 null main "$NEWER"), $(run_entry 5 success main "$WM")]"
run_script "$D"
expect_rc 0
expect_output watermark "$WM"

# --- 4. branch scoping -----------------------------------------------------

start 'ignores a successful run on another branch'
D=$(new_fixture_dir)
write_page "$D" 1 "[$(run_entry 2 success feature/x "$NEWER"), $(run_entry 1 success main "$WM")]"
run_script "$D" BRANCH='main'
expect_rc 0
expect_output watermark "$WM"

start "counts every branch when branch is '*'"
run_script "$D" BRANCH='*'
expect_rc 0
expect_output watermark "$NEWER"

# --- 5. self-exclusion -----------------------------------------------------

start 'ignores the excluded run id, so a re-run cannot be its own watermark'
D=$(new_fixture_dir)
write_page "$D" 1 "[$(run_entry 4242 success main "$NEWER"), $(run_entry 1 success main "$WM")]"
run_script "$D" EXCLUDE_RUN_ID='4242'
expect_rc 0
expect_output watermark "$WM"

# --- 6. pagination ---------------------------------------------------------

start 'pages past a full page of non-successes'
D=$(new_fixture_dir)
write_filler_page "$D" 1 100
write_page "$D" 2 "[$(run_entry 1 success main "$WM")]"
run_script "$D"
expect_rc 0
expect_output watermark "$WM"
expect_output pages-scanned '2'
expect_output runs-scanned '101'
expect_stderr_has 'no successful run on page 1'

start 'stops at a partial page rather than requesting another'
D=$(new_fixture_dir)
write_filler_page "$D" 1 99
run_script "$D" INITIAL_WINDOW='24h'
expect_rc 0
expect_output source 'initial-window'
expect_output pages-scanned '1'

# --- 7. nothing has ever succeeded -----------------------------------------

start 'fails when nothing has ever succeeded and no initial window is given'
D=$(new_fixture_dir)
write_page "$D" 1 "[$(run_entry 1 failure main "$OLD")]"
run_script "$D"
expect_rc 1
expect_stderr_has 'has ever succeeded'
expect_stderr_has 'Refusing to guess'

start 'uses initial-window when nothing has ever succeeded'
run_script "$D" INITIAL_WINDOW='24h'
expect_rc 0
expect_output source 'initial-window'
expect_output watermark "$(iso $((NOW - 86400)))"
expect_output from-epoch "$((NOW - 86400 - 60))"
expect_output is-catchup 'true'
expect_stderr_has 'brand-new workflow'

start 'accepts an absolute initial-window'
run_script "$D" INITIAL_WINDOW="$OLD"
expect_rc 0
expect_output watermark "$OLD"

start 'rejects an unparseable initial-window'
run_script "$D" INITIAL_WINDOW='last tuesday'
expect_rc 1
expect_stderr_has 'INITIAL_WINDOW is neither a duration'

# --- 8. the page cap is fatal and cannot be rescued ------------------------

start 'fails when the page cap is hit with runs still unscanned'
D=$(new_fixture_dir)
write_filler_page "$D" 1 100
write_filler_page "$D" 2 100
run_script "$D" MAX_PAGES='2'
expect_rc 1
expect_stderr_has 'cannot be bounded'
expect_output runs-scanned ''

start 'initial-window does NOT rescue a page-cap failure'
run_script "$D" MAX_PAGES='2' INITIAL_WINDOW='24h'
expect_rc 1
expect_stderr_has 'cannot be bounded'
expect_stderr_lacks 'brand-new workflow'

# --- 9. override ------------------------------------------------------------

start 'override-start-time skips the run history entirely'
D=$(new_fixture_dir)
write_page "$D" 1 "[$(run_entry 1 success main "$WM")]"
run_script "$D" OVERRIDE_START_TIME="$OLD"
expect_rc 0
expect_output source 'override'
expect_output watermark "$OLD"
expect_output runs-scanned '0'
expect_output pages-scanned '0'

start 'override-start-time accepts a duration'
run_script "$D" OVERRIDE_START_TIME='2h'
expect_rc 0
expect_output source 'override'
expect_output watermark "$(iso $((NOW - 7200)))"

start 'override wins over an empty run history'
D=$(new_fixture_dir)
run_script "$D" OVERRIDE_START_TIME='45m'
expect_rc 0
expect_output watermark "$(iso $((NOW - 2700)))"

start 'rejects an unparseable override-start-time'
run_script "$D" OVERRIDE_START_TIME='yesterday-ish'
expect_rc 1
expect_stderr_has 'OVERRIDE_START_TIME is neither a duration'

# --- 10. duration units ----------------------------------------------------

start 'understands s, m, h and d durations'
D=$(new_fixture_dir)
run_script "$D" OVERRIDE_START_TIME='90s'
expect_output watermark "$(iso $((NOW - 90)))"
run_script "$D" OVERRIDE_START_TIME='45m'
expect_output watermark "$(iso $((NOW - 2700)))"
run_script "$D" OVERRIDE_START_TIME='12h'
expect_output watermark "$(iso $((NOW - 43200)))"
run_script "$D" OVERRIDE_START_TIME='7d'
expect_output watermark "$(iso $((NOW - 604800)))"

# --- 11. the overlap -------------------------------------------------------

start 'applies overlap-seconds to produce from'
D=$(new_fixture_dir)
write_page "$D" 1 "[$(run_entry 1 success main "$WM")]"
run_script "$D" OVERLAP_SECONDS='300'
expect_output from-epoch "$((WM_EPOCH - 300))"

start 'accepts a zero overlap'
run_script "$D" OVERLAP_SECONDS='0'
expect_rc 0
expect_output from-epoch "$WM_EPOCH"
expect_output from "$WM"

# --- 12. catch-up detection ------------------------------------------------

start 'flags a wide window as a catch-up'
D=$(new_fixture_dir)
write_page "$D" 1 "[$(run_entry 1 success main "$OLD")]"
run_script "$D"
expect_rc 0
expect_output age-hours '30'
expect_output is-catchup 'true'
expect_stderr_has 'catching up after a gap'

start 'does not flag a normal window'
D=$(new_fixture_dir)
write_page "$D" 1 "[$(run_entry 1 success main "$WM")]"
run_script "$D"
expect_output is-catchup 'false'
expect_stderr_lacks 'catching up'

start 'honours a custom wide-window-hours'
run_script "$D" WIDE_WINDOW_HOURS='0'
expect_output is-catchup 'true'

# --- 13. a watermark in the future -----------------------------------------

start 'reports a future watermark instead of clamping it'
D=$(new_fixture_dir)
write_page "$D" 1 "[$(run_entry 1 success main "$FUTURE")]"
run_script "$D"
expect_rc 0
expect_output age-seconds '-900'
expect_output age-hours '0'
expect_stderr_has 'in the FUTURE'

# --- 14. GITHUB_OUTPUT -----------------------------------------------------

start 'writes the same values to GITHUB_OUTPUT'
D=$(new_fixture_dir)
write_page "$D" 1 "[$(run_entry 1 success main "$WM")]"
GH_OUT="$WORKDIR/gh_output"
: > "$GH_OUT"
run_script "$D" GITHUB_OUTPUT="$GH_OUT"
expect_rc 0
expect_eq "$case_name: from in GITHUB_OUTPUT" \
  "from=$(iso $((WM_EPOCH - 60)))" \
  "$(grep '^from=' "$GH_OUT")"
expect_eq "$case_name: every stdout pair is in GITHUB_OUTPUT" \
  "$(printf '%s\n' "$OUT" | grep -c '=')" \
  "$(grep -c '=' "$GH_OUT")"

# --- 15. malformed pages ---------------------------------------------------

start 'treats a page with no workflow_runs key as the end of the history'
D=$(new_fixture_dir)
echo '{}' > "$D/page1.json"
run_script "$D" INITIAL_WINDOW='1h'
expect_rc 0
expect_output source 'initial-window'
expect_output runs-scanned '0'

start 'treats an absent page 1 as an empty history'
D=$(new_fixture_dir)
run_script "$D"
expect_rc 1
expect_stderr_has 'has ever succeeded'

# --- 16. input validation --------------------------------------------------

start 'rejects a workflow path instead of a file name'
D=$(new_fixture_dir)
run_script "$D" WORKFLOW='.github/workflows/track.yml'
expect_rc 1
expect_stderr_has 'bare file name'

start 'rejects a workflow display name'
run_script "$D" WORKFLOW='Track Publishes'
expect_rc 1
expect_stderr_has '.yml or .yaml'

start 'accepts a .yaml workflow'
write_page "$D" 1 "[$(run_entry 1 success main "$WM")]"
run_script "$D" WORKFLOW='track.yaml'
expect_rc 0

start 'rejects a non-numeric overlap'
run_script "$D" OVERLAP_SECONDS='sixty'
expect_rc 1
expect_stderr_has 'must be a non-negative integer'

start 'rejects a per-page above 100'
run_script "$D" PER_PAGE='500'
expect_rc 1
expect_stderr_has 'between 1 and 100'

start 'rejects a zero max-pages'
run_script "$D" MAX_PAGES='0'
expect_rc 1
expect_stderr_has 'at least 1'

start 'requires REPOSITORY'
run_script "$D" REPOSITORY=''
expect_rc 1
expect_stderr_has 'REPOSITORY'

# --- 17. no network without fixtures ---------------------------------------

start 'refuses to call the API without a token'
run_script '' GITHUB_TOKEN=''
expect_rc 1
expect_stderr_has 'GITHUB_TOKEN is required'

rm -rf "$WORKDIR"
# --- summary ---------------------------------------------------------------

echo
echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
