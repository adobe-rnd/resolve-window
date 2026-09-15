#! /usr/bin/env bash
#
# Tests for restore-checkpoint.sh and save-checkpoint.sh.
#
# Both real scripts are executed; nothing is reimplemented here. The clock is pinned with
# NOW_EPOCH so pruning arithmetic is exact, and every case works on a fresh temp directory
# so no case can inherit another's checkpoint.
#
# Usage: tests/checkpoint.test.sh
#
# `set -e` is not used: most cases assert on a non-zero exit code.

TESTS_DIR=$(cd "$(dirname "$0")" && pwd)
RESTORE="$TESTS_DIR/../restore-checkpoint.sh"
SAVE="$TESTS_DIR/../save-checkpoint.sh"

for f in "$RESTORE" "$SAVE"; do
  if [ ! -f "$f" ]; then
    echo "cannot find $f" >&2
    exit 1
  fi
done

pass=0
fail=0
case_name=''

NOW=1789452000
WORKDIR=$(mktemp -d)

start() { case_name="$1"; }
ok() { pass=$((pass + 1)); printf '    ok    %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '    FAIL  %s\n         %s\n' "$1" "$2"; }

fresh() {
  local d
  d=$(mktemp -d "$WORKDIR/cp.XXXXXX")
  printf '%s/checkpoint.json\n' "$d"
}

run_restore() {
  local cp="$1"
  shift
  local errfile="$WORKDIR/err.restore"
  # The environment is built INSIDE the subshell on purpose: each call must run the script
  # with a known environment and leave the caller's untouched. Nothing outside the subshell
  # reads these variables, so shellcheck's warning that the changes are lost is the point.
  # (Also the only portable option here: a prefix assignment cannot set a variable for a
  # script invoked through several layers, and `env VAR=VAL` is not dependable everywhere.)
  # shellcheck disable=SC2030,SC2031
  OUT=$(
    export CHECKPOINT_FILE="$cp"
    export GITHUB_OUTPUT=''
    for kv in "$@"; do
      # shellcheck disable=SC2163 # kv is a NAME=VALUE pair
      export "$kv"
    done
    bash "$RESTORE" 2>"$errfile"
  )
  RC=$?
  ERR=$(cat "$errfile" 2>/dev/null)
}

run_save() {
  local cp="$1"
  shift
  local errfile="$WORKDIR/err.save"
  # The environment is built INSIDE the subshell on purpose: each call must run the script
  # with a known environment and leave the caller's untouched. Nothing outside the subshell
  # reads these variables, so shellcheck's warning that the changes are lost is the point.
  # (Also the only portable option here: a prefix assignment cannot set a variable for a
  # script invoked through several layers, and `env VAR=VAL` is not dependable everywhere.)
  # shellcheck disable=SC2030,SC2031
  OUT=$(
    export CHECKPOINT_FILE="$cp"
    export NOW_EPOCH="$NOW"
    export TIMESTAMP=''
    export CURSOR=''
    export PAGE=''
    export SEEN_IDS=''
    export SEEN_IDS_FILE=''
    export SEEN_WINDOW_SECONDS='60'
    export ALLOW_REWIND='false'
    export GITHUB_OUTPUT=''
    for kv in "$@"; do
      # shellcheck disable=SC2163 # kv is a NAME=VALUE pair
      export "$kv"
    done
    bash "$SAVE" 2>"$errfile"
  )
  RC=$?
  ERR=$(cat "$errfile" 2>/dev/null)
}

out_value() { printf '%s\n' "$OUT" | grep "^$1=" | head -1 | cut -d= -f2-; }

expect_eq() {
  local label="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then ok "$label"; else bad "$label" "wanted '$want', got '$got'"; fi
}

expect_output() { expect_eq "$case_name: $1=$2" "$2" "$(out_value "$1")"; }
expect_rc() { expect_eq "$case_name: exit $1" "$1" "$RC"; }

expect_stderr_has() {
  case "$ERR" in
    *"$1"*) ok "$case_name: stderr mentions '$1'" ;;
    *) bad "$case_name: stderr mentions '$1'" "stderr: $(printf '%s' "$ERR" | tr '\n' ' ' | cut -c1-180)" ;;
  esac
}

expect_stderr_lacks() {
  case "$ERR" in
    *"$1"*) bad "$case_name: stderr must not mention '$1'" "stderr: $(printf '%s' "$ERR" | tr '\n' ' ' | cut -c1-180)" ;;
    *) ok "$case_name: stderr does not mention '$1'" ;;
  esac
}

expect_json() {
  local cp="$1" filter="$2" want="$3"
  local got
  got=$(jq -r "$filter" "$cp" 2>/dev/null)
  expect_eq "$case_name: $filter == $want" "$want" "$got"
}

echo "checkpoint restore + save"

# --- restore: nothing to restore -------------------------------------------

start 'reports no checkpoint when the file is absent'
CP=$(fresh)
run_restore "$CP"
expect_rc 0
expect_output checkpoint-kind 'none'
expect_output resumable 'false'
expect_output seen-ids-count '0'
expect_stderr_has 'no checkpoint at'

start 'ignores a checkpoint that is not valid JSON'
CP=$(fresh)
mkdir -p "${CP%/*}"
printf 'not json at all' > "$CP"
run_restore "$CP"
expect_rc 0
expect_output checkpoint-kind 'none'
expect_stderr_has 'not valid JSON'

start 'ignores a checkpoint with an unrecognised kind'
CP=$(fresh)
mkdir -p "${CP%/*}"
echo '{"kind":"magic","timestamp":"2026-09-15T10:00:00Z"}' > "$CP"
run_restore "$CP"
expect_output checkpoint-kind 'none'
expect_stderr_has 'unrecognised kind'

start 'ignores a checkpoint with no kind'
CP=$(fresh)
mkdir -p "${CP%/*}"
echo '{"timestamp":"2026-09-15T10:00:00Z"}' > "$CP"
run_restore "$CP"
expect_output checkpoint-kind 'none'
expect_stderr_has 'no kind'

# --- restore: a claimed kind must carry its position ------------------------

start 'refuses a kind=cursor checkpoint that records no cursor'
CP=$(fresh)
mkdir -p "${CP%/*}"
echo '{"kind":"cursor","cursor":"","timestamp":"2026-09-15T10:00:00Z"}' > "$CP"
run_restore "$CP"
expect_output checkpoint-kind 'none'
expect_stderr_has 'records no cursor'

start 'refuses a kind=page checkpoint that records no page'
CP=$(fresh)
mkdir -p "${CP%/*}"
echo '{"kind":"page","timestamp":"2026-09-15T10:00:00Z"}' > "$CP"
run_restore "$CP"
expect_output checkpoint-kind 'none'
expect_stderr_has 'records no page'

start 'refuses a kind=timestamp checkpoint that records no timestamp'
CP=$(fresh)
mkdir -p "${CP%/*}"
echo '{"kind":"timestamp"}' > "$CP"
run_restore "$CP"
expect_output checkpoint-kind 'none'
expect_stderr_has 'records no timestamp'

# --- restore: the happy paths ----------------------------------------------

start 'restores a timestamp checkpoint'
CP=$(fresh)
mkdir -p "${CP%/*}"
echo '{"kind":"timestamp","timestamp":"2026-09-15T10:00:00Z","committedAt":"2026-09-15T10:00:30Z","runId":"42","seen":[{"id":"a1","atEpoch":1}]}' > "$CP"
run_restore "$CP"
expect_rc 0
expect_output checkpoint-kind 'timestamp'
expect_output resumable 'true'
expect_output timestamp '2026-09-15T10:00:00Z'
expect_output committed-at '2026-09-15T10:00:30Z'
expect_output committed-run '42'
expect_output seen-ids-count '1'
expect_eq "$case_name: the seen file holds the id" 'a1' "$(cat "$(out_value seen-ids-file)")"

start 'restores a cursor checkpoint'
CP=$(fresh)
mkdir -p "${CP%/*}"
echo '{"kind":"cursor","cursor":"ABAB==","timestamp":"2026-09-15T10:00:00Z"}' > "$CP"
run_restore "$CP"
expect_output checkpoint-kind 'cursor'
expect_output cursor 'ABAB=='
expect_output timestamp '2026-09-15T10:00:00Z'
expect_stderr_lacks 'no time-based recovery path'

start 'warns when a cursor has no timestamp to fall back to'
CP=$(fresh)
mkdir -p "${CP%/*}"
echo '{"kind":"cursor","cursor":"ABAB=="}' > "$CP"
run_restore "$CP"
expect_output checkpoint-kind 'cursor'
expect_stderr_has 'no time-based recovery path'

start 'restores a page checkpoint'
CP=$(fresh)
mkdir -p "${CP%/*}"
echo '{"kind":"page","page":3,"timestamp":"2026-09-15T10:00:00Z"}' > "$CP"
run_restore "$CP"
expect_output checkpoint-kind 'page'
expect_output page '3'

# --- save: the basics ------------------------------------------------------

start 'saves a timestamp checkpoint'
CP=$(fresh)
run_save "$CP" TIMESTAMP='2026-09-15T10:00:00Z' SEEN_IDS='a1
b2'
expect_rc 0
expect_output checkpoint-kind 'timestamp'
expect_output timestamp '2026-09-15T10:00:00Z'
expect_output seen-ids-count '2'
expect_output rewound 'false'
expect_json "$CP" '.kind' 'timestamp'
expect_json "$CP" '.timestamp' '2026-09-15T10:00:00Z'
expect_json "$CP" '.seen | length' '2'

start 'saves a cursor, which outranks a page'
CP=$(fresh)
run_save "$CP" CURSOR='ABAB==' PAGE='7' TIMESTAMP='2026-09-15T10:00:00Z'
expect_output checkpoint-kind 'cursor'
expect_json "$CP" '.cursor' 'ABAB=='
expect_json "$CP" '.page' '7'
expect_stderr_has 'the cursor wins'

start 'saves a page when no cursor is given'
CP=$(fresh)
run_save "$CP" PAGE='4' TIMESTAMP='2026-09-15T10:00:00Z'
expect_output checkpoint-kind 'page'
expect_json "$CP" '.page' '4'

start 'warns when a cursor is saved with no timestamp'
CP=$(fresh)
run_save "$CP" CURSOR='ABAB=='
expect_rc 0
expect_output checkpoint-kind 'cursor'
expect_stderr_has 'no time-based recovery path'

start 'refuses to save nothing at all'
CP=$(fresh)
run_save "$CP"
expect_rc 1
expect_stderr_has 'nothing to record'

start 'rejects a non-numeric page'
CP=$(fresh)
run_save "$CP" PAGE='three' TIMESTAMP='2026-09-15T10:00:00Z'
expect_rc 1
expect_stderr_has 'PAGE must be a non-negative integer'

start 'rejects a non-numeric seen window'
CP=$(fresh)
run_save "$CP" TIMESTAMP='2026-09-15T10:00:00Z' SEEN_WINDOW_SECONDS='sixty'
expect_rc 1
expect_stderr_has 'SEEN_WINDOW_SECONDS must be'

start 'rejects an unparseable timestamp'
CP=$(fresh)
run_save "$CP" TIMESTAMP='xyzzy'
expect_rc 1
expect_stderr_has 'not a parseable timestamp'

# --- save: committing twice in one run -------------------------------------
#
# The second commit reaches the file but cannot reach the cache, because both saves derive
# the same immutable key from the same run id and attempt. Silent in v1.1.0 CI until the log
# was read, so it gets a warning and a test.

start 'warns when the same run attempt commits twice'
CP=$(fresh)
run_save "$CP" TIMESTAMP='2026-09-15T10:00:00Z' GITHUB_RUN_ID='111' GITHUB_RUN_ATTEMPT='1'
expect_rc 0
expect_stderr_lacks 'already committed a checkpoint'
run_save "$CP" TIMESTAMP='2026-09-15T11:00:00Z' GITHUB_RUN_ID='111' GITHUB_RUN_ATTEMPT='1'
expect_rc 0
expect_stderr_has 'already committed a checkpoint'
# It is a warning, not a refusal: the file must still hold the newer mark, since a caller
# that genuinely wants two commits in one run can give the second its own namespace.
expect_json "$CP" '.timestamp' '2026-09-15T11:00:00Z'

start 'a second commit under its own cache key is not a double commit'
CP=$(fresh)
run_save "$CP" TIMESTAMP='2026-09-15T10:00:00Z' GITHUB_RUN_ID='111' GITHUB_RUN_ATTEMPT='1' KEY_PREFIX='rw-main'
run_save "$CP" TIMESTAMP='2026-09-15T11:00:00Z' GITHUB_RUN_ID='111' GITHUB_RUN_ATTEMPT='1' KEY_PREFIX='rw-other'
expect_rc 0
# The remedy must not be reported as the problem: a different namespace means a different
# key, so nothing is lost and there is nothing to warn about.
expect_stderr_lacks 'already committed a checkpoint'

start 'a second commit under the same cache key is a double commit'
CP=$(fresh)
run_save "$CP" TIMESTAMP='2026-09-15T10:00:00Z' GITHUB_RUN_ID='111' GITHUB_RUN_ATTEMPT='1' KEY_PREFIX='rw-main'
run_save "$CP" TIMESTAMP='2026-09-15T11:00:00Z' GITHUB_RUN_ID='111' GITHUB_RUN_ATTEMPT='1' KEY_PREFIX='rw-main'
expect_rc 0
expect_stderr_has 'already committed a checkpoint'

start 'a later run committing over an earlier one is not a double commit'
CP=$(fresh)
run_save "$CP" TIMESTAMP='2026-09-15T10:00:00Z' GITHUB_RUN_ID='111' GITHUB_RUN_ATTEMPT='1'
run_save "$CP" TIMESTAMP='2026-09-15T11:00:00Z' GITHUB_RUN_ID='222' GITHUB_RUN_ATTEMPT='1'
expect_rc 0
expect_stderr_lacks 'already committed a checkpoint'

start 'a retried attempt of the same run is not a double commit'
CP=$(fresh)
run_save "$CP" TIMESTAMP='2026-09-15T10:00:00Z' GITHUB_RUN_ID='111' GITHUB_RUN_ATTEMPT='1'
run_save "$CP" TIMESTAMP='2026-09-15T11:00:00Z' GITHUB_RUN_ID='111' GITHUB_RUN_ATTEMPT='2'
expect_rc 0
expect_stderr_lacks 'already committed a checkpoint'

# --- save: the rewind guard ------------------------------------------------

start 'refuses to move the mark backwards'
CP=$(fresh)
run_save "$CP" TIMESTAMP='2026-09-15T10:00:00Z'
run_save "$CP" TIMESTAMP='2026-09-15T09:00:00Z'
expect_rc 0
expect_output timestamp '2026-09-15T10:00:00Z'
expect_output rewound 'false'
expect_stderr_has 'refusing to move the checkpoint backwards'
expect_json "$CP" '.timestamp' '2026-09-15T10:00:00Z'

start 'rewinds when allow-rewind is set'
CP=$(fresh)
run_save "$CP" TIMESTAMP='2026-09-15T10:00:00Z'
run_save "$CP" TIMESTAMP='2026-09-15T09:00:00Z' ALLOW_REWIND='true'
expect_output timestamp '2026-09-15T09:00:00Z'
expect_output rewound 'true'
expect_stderr_has 'being rewound'

start 'accepts a mark that moves forwards'
CP=$(fresh)
run_save "$CP" TIMESTAMP='2026-09-15T10:00:00Z'
run_save "$CP" TIMESTAMP='2026-09-15T10:05:00Z'
expect_output timestamp '2026-09-15T10:05:00Z'
expect_stderr_lacks 'refusing to move'

start 'inherits the stored mark when none is supplied'
CP=$(fresh)
run_save "$CP" TIMESTAMP='2026-09-15T10:00:00Z'
run_save "$CP" SEEN_IDS='z9'
expect_rc 0
expect_output timestamp '2026-09-15T10:00:00Z'
expect_stderr_has 'the stored mark 2026-09-15T10:00:00Z is kept'

# --- save: seen-id merging and pruning ------------------------------------

start 'keeps ids inside the retention window and drops the rest'
CP=$(fresh)
run_save "$CP" TIMESTAMP='2026-09-15T10:00:00Z' SEEN_IDS='old1' SEEN_WINDOW_SECONDS='60'
# Move the mark 120s forward: old1 was recorded 120s ago, outside a 60s window.
run_save "$CP" TIMESTAMP='2026-09-15T10:02:00Z' SEEN_IDS='new1' SEEN_WINDOW_SECONDS='60'
expect_output seen-ids-count '1'
expect_output seen-ids-pruned '1'
expect_json "$CP" '.seen[0].id' 'new1'

start 'keeps an older id while it is still inside the window'
CP=$(fresh)
run_save "$CP" TIMESTAMP='2026-09-15T10:00:00Z' SEEN_IDS='old1' SEEN_WINDOW_SECONDS='300'
run_save "$CP" TIMESTAMP='2026-09-15T10:02:00Z' SEEN_IDS='new1' SEEN_WINDOW_SECONDS='300'
expect_output seen-ids-count '2'
expect_output seen-ids-pruned '0'

start 'collapses a repeated id to one entry, keeping the newest mark'
CP=$(fresh)
run_save "$CP" TIMESTAMP='2026-09-15T10:00:00Z' SEEN_IDS='dup' SEEN_WINDOW_SECONDS='600'
run_save "$CP" TIMESTAMP='2026-09-15T10:05:00Z' SEEN_IDS='dup' SEEN_WINDOW_SECONDS='600'
expect_output seen-ids-count '1'
expect_json "$CP" '.seen[0].at' '2026-09-15T10:05:00Z'

start 'reads ids from a file as well as the variable'
CP=$(fresh)
IDS="$WORKDIR/ids.txt"
printf 'f1\nf2\n' > "$IDS"
run_save "$CP" TIMESTAMP='2026-09-15T10:00:00Z' SEEN_IDS_FILE="$IDS" SEEN_IDS='v1'
expect_output seen-ids-count '3'

start 'ignores blank lines among the ids'
CP=$(fresh)
run_save "$CP" TIMESTAMP='2026-09-15T10:00:00Z' SEEN_IDS='a

b'
expect_output seen-ids-count '2'

start 'a zero retention window keeps only ids at the mark itself'
CP=$(fresh)
run_save "$CP" TIMESTAMP='2026-09-15T10:00:00Z' SEEN_IDS='boundary' SEEN_WINDOW_SECONDS='0'
expect_output seen-ids-count '1'
run_save "$CP" TIMESTAMP='2026-09-15T10:00:01Z' SEEN_IDS='next' SEEN_WINDOW_SECONDS='0'
expect_output seen-ids-count '1'
expect_json "$CP" '.seen[0].id' 'next'

# --- round trip -----------------------------------------------------------

start 'a saved checkpoint restores to the same values'
CP=$(fresh)
run_save "$CP" TIMESTAMP='2026-09-15T10:00:00Z' SEEN_IDS='r1
r2' SEEN_WINDOW_SECONDS='600'
run_restore "$CP"
expect_rc 0
expect_output checkpoint-kind 'timestamp'
expect_output resumable 'true'
expect_output timestamp '2026-09-15T10:00:00Z'
expect_output seen-ids-count '2'
expect_eq "$case_name: the seen file lists both ids" 'r1 r2' \
  "$(sort "$(out_value seen-ids-file)" | tr '\n' ' ' | sed 's/ $//')"

start 'a saved cursor restores as a cursor'
CP=$(fresh)
run_save "$CP" CURSOR='tok-123' TIMESTAMP='2026-09-15T10:00:00Z'
run_restore "$CP"
expect_output checkpoint-kind 'cursor'
expect_output cursor 'tok-123'
expect_output timestamp '2026-09-15T10:00:00Z'

start 'the checkpoint file is always valid JSON after a save'
CP=$(fresh)
run_save "$CP" TIMESTAMP='2026-09-15T10:00:00Z' SEEN_IDS='j1'
expect_eq "$case_name: jq parses it" 'ok' "$(jq -e . "$CP" >/dev/null 2>&1 && echo ok || echo broken)"
expect_eq "$case_name: no temp file left behind" '0' \
  "$(find "${CP%/*}" -name '*.tmp.*' 2>/dev/null | grep -c . )"

echo
echo "  $pass passed, $fail failed"
rm -rf "$WORKDIR"
[ "$fail" -eq 0 ] || exit 1
