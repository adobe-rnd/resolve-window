#! /usr/bin/env bash
#
# Resolve the monitoring watermark for an incremental job: the `created_at` of the
# most recent SUCCESSFUL run of a workflow, and the processing window derived from it.
#
# This is the state-handling half of the common "cron -> watermark -> drain a log API
# -> filter -> act" pattern. The drain itself is deliberately NOT here: every log API
# paginates, authenticates and expresses time differently, so that part belongs to the
# caller. Everything up to writing `from` to $GITHUB_OUTPUT is reusable; everything
# from "authenticate to the API and fetch the first page" is not.
#
# Configuration is read from the environment so that action.yml can map `with:` inputs
# to it directly. See action.yml for the documented input surface.
#
#   REPOSITORY            owner/repo to query                      (required)
#   WORKFLOW              workflow file name, e.g. track.yml        (required)
#   BRANCH                only count runs on this branch; '' or '*' for any
#   EXCLUDE_RUN_ID        run id to ignore, normally this run       (optional)
#   OVERLAP_SECONDS       lookback subtracted from the watermark    (default 60)
#   MAX_PAGES             run-history pages to scan                 (default 10)
#   PER_PAGE              runs per page, max 100                    (default 100)
#   WIDE_WINDOW_HOURS     warn when the window is at least this old (default 6)
#   CHECKPOINT_TIMESTAMP  watermark from a restored checkpoint      (optional)
#   OVERRIDE_START_TIME   skip the API and use this start           (optional)
#   INITIAL_WINDOW        first-run fallback: duration or timestamp (optional)
#   GITHUB_TOKEN          token for the runs API                    (required unless fixtures)
#   RUNS_FIXTURE_DIR      read page<N>.json from here, make no API call (tests only)
#   NOW_EPOCH             override "now", for deterministic tests   (tests only)
#
# Outputs are written to $GITHUB_OUTPUT when set, and always echoed to stdout as
# `name=value` so the script is usable and testable outside Actions.
#
# The contract has exactly three outcomes, and two of them are fatal on purpose:
#
#   0  A watermark was resolved. Sets source to one of:
#        override        an explicit start was supplied
#        checkpoint      the data's own clock, from a restored checkpoint
#        last-success    the created_at of this workflow's last successful run
#        initial-window  nothing has ever succeeded, and a first window was given
#
#   1  THE WINDOW COULD NOT BE BOUNDED: the page cap was reached while runs remained
#      unscanned. Always fatal, and deliberately not configurable. Any fallback here
#      would silently skip every event older than the guessed window, which looks
#      exactly like a clean run. Raise MAX_PAGES or pass OVERRIDE_START_TIME.
#
#   1  NO RUN HAS EVER SUCCEEDED and no INITIAL_WINDOW was given. Fatal, because
#      guessing has the same silent-skip failure mode. Set INITIAL_WINDOW to opt into
#      a bounded first window (this is the only legitimate case for a default).
#
# Why the run history is paged and filtered locally rather than using `?status=success`:
# that server-side filter is not dependable on a high-volume workflow. On a workflow
# with roughly 28,000 runs, five identical `?status=success` calls returned total_count
# anywhere between 716 and 12,670, serving months-stale pages. The UNFILTERED list is
# stable and ordered newest-first, so it is paged and filtered here. One page is not
# enough either: an outage or a `cancel-in-progress` backlog can fill 100 consecutive
# runs with no success (54 of the most recent 100, on the workflow that motivated this).
#
set -euo pipefail

REPOSITORY="${REPOSITORY:?REPOSITORY (owner/repo) is required}"
WORKFLOW="${WORKFLOW:?WORKFLOW (workflow file name) is required}"
BRANCH="${BRANCH:-}"
EXCLUDE_RUN_ID="${EXCLUDE_RUN_ID:-}"
OVERLAP_SECONDS="${OVERLAP_SECONDS:-60}"
MAX_PAGES="${MAX_PAGES:-10}"
PER_PAGE="${PER_PAGE:-100}"
WIDE_WINDOW_HOURS="${WIDE_WINDOW_HOURS:-6}"
CHECKPOINT_TIMESTAMP="${CHECKPOINT_TIMESTAMP:-}"
OVERRIDE_START_TIME="${OVERRIDE_START_TIME:-}"
INITIAL_WINDOW="${INITIAL_WINDOW:-}"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"
RUNS_FIXTURE_DIR="${RUNS_FIXTURE_DIR:-}"
NOW_EPOCH="${NOW_EPOCH:-}"

# --- helpers ----------------------------------------------------------------

die() {
  echo "::error::$*" >&2
  exit 1
}

note() { echo "$*" >&2; }

warn() { echo "::warning::$*" >&2; }

# A workflow file name, not a path or a ref. Accepts what GITHUB_WORKFLOW_REF yields
# after action.yml has trimmed it, and rejects the mistake of passing a display name.
case "$WORKFLOW" in
  */*) die "WORKFLOW must be a bare file name, not a path: got '$WORKFLOW'" ;;
  *.yml | *.yaml) : ;;
  *) die "WORKFLOW must be a workflow file name ending in .yml or .yaml: got '$WORKFLOW'" ;;
esac

# Validated with [[ =~ ]] rather than a `case` glob: the negated class [!0-9] is
# mishandled by some shells, which then reject perfectly good integers.
for var in OVERLAP_SECONDS MAX_PAGES PER_PAGE WIDE_WINDOW_HOURS; do
  if [[ ! "${!var}" =~ ^[0-9]+$ ]]; then
    die "$var must be a non-negative integer: got '${!var}'"
  fi
done

if [ "$MAX_PAGES" -lt 1 ]; then
  die "MAX_PAGES must be at least 1"
fi

if [ "$PER_PAGE" -lt 1 ] || [ "$PER_PAGE" -gt 100 ]; then
  die "PER_PAGE must be between 1 and 100"
fi

# GNU date first, BSD/macOS second, so the action is not silently Linux-only.
to_epoch() {
  local ts="$1" out
  if out=$(date -u -d "$ts" +%s 2>/dev/null); then printf '%s\n' "$out"; return 0; fi
  if out=$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$ts" +%s 2>/dev/null); then printf '%s\n' "$out"; return 0; fi
  return 1
}

from_epoch() {
  local e="$1" out
  if out=$(date -u -d "@$e" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null); then printf '%s\n' "$out"; return 0; fi
  if out=$(date -u -r "$e" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null); then printf '%s\n' "$out"; return 0; fi
  return 1
}

# A duration like 30s/45m/12h/7d, or an absolute timestamp. Returns epoch seconds.
resolve_start_spec() {
  local spec="$1" label="$2" n unit secs
  if [[ "$spec" =~ ^([0-9]+)([smhd])$ ]]; then
    n="${BASH_REMATCH[1]}"
    unit="${BASH_REMATCH[2]}"
    case "$unit" in
      s) secs=$((n)) ;;
      m) secs=$((n * 60)) ;;
      h) secs=$((n * 3600)) ;;
      d) secs=$((n * 86400)) ;;
    esac
    printf '%s\n' "$((NOW - secs))"
    return 0
  fi
  local e
  e=$(to_epoch "$spec") || die "$label is neither a duration (30s, 45m, 12h, 7d) nor a parseable timestamp: got '$spec'"
  printf '%s\n' "$e"
}

NOW=$(date -u +%s)
if [ -n "$NOW_EPOCH" ]; then
  if [[ ! "$NOW_EPOCH" =~ ^[0-9]+$ ]]; then
    die "NOW_EPOCH must be epoch seconds: got '$NOW_EPOCH'"
  fi
  NOW="$NOW_EPOCH"
fi

fetch_page() {
  local page="$1" fixture url body status
  if [ -n "$RUNS_FIXTURE_DIR" ]; then
    fixture="$RUNS_FIXTURE_DIR/page$page.json"
    if [ -f "$fixture" ]; then
      cat "$fixture"
    else
      # An absent fixture stands for "no more runs", which is how the real API ends.
      echo '{"workflow_runs":[]}'
    fi
    return 0
  fi

  [ -n "$GITHUB_TOKEN" ] || die "GITHUB_TOKEN is required to read the run history of $REPOSITORY"

  url="https://api.github.com/repos/$REPOSITORY/actions/workflows/$WORKFLOW/runs?per_page=$PER_PAGE&page=$page"
  # Status is appended on its own line so a transport or auth failure is never mistaken
  # for an empty page, which would end the scan early and bound the window wrongly.
  body=$(curl -sS -w '\n%{http_code}' \
    -H "Authorization: Bearer $GITHUB_TOKEN" \
    -H 'Accept: application/vnd.github+json' \
    -H 'X-GitHub-Api-Version: 2022-11-28' \
    "$url") || die "the run-history request failed for $REPOSITORY ($WORKFLOW, page $page)"
  status=$(printf '%s' "$body" | tail -n 1)
  body=$(printf '%s' "$body" | sed '$d')

  case "$status" in
    200) printf '%s\n' "$body" ;;
    404) die "no such workflow or repository: $REPOSITORY/$WORKFLOW (404). Check the workflow file name." ;;
    401 | 403) die "the token was refused reading $REPOSITORY run history ($status). The job needs 'permissions: actions: read'." ;;
    *) die "the run-history request for $REPOSITORY/$WORKFLOW returned HTTP $status" ;;
  esac
}

# --- resolve the watermark --------------------------------------------------

watermark=''
source_kind=''
scanned=0
pages=0
exhausted=false

if [ -n "$OVERRIDE_START_TIME" ]; then
  start_epoch=$(resolve_start_spec "$OVERRIDE_START_TIME" 'OVERRIDE_START_TIME')
  watermark=$(from_epoch "$start_epoch")
  source_kind='override'
  note "watermark $watermark (from OVERRIDE_START_TIME=$OVERRIDE_START_TIME; the run history was not consulted)"
fi

# A checkpoint timestamp comes from the drained API's own data, so it is preferred over
# GitHub's run history: it is immune to Actions queue delay and to clock skew between the
# runner and the API. An explicit override still outranks it.
if [ -z "$watermark" ] && [ -n "$CHECKPOINT_TIMESTAMP" ]; then
  start_epoch=$(resolve_start_spec "$CHECKPOINT_TIMESTAMP" 'CHECKPOINT_TIMESTAMP')
  watermark=$(from_epoch "$start_epoch")
  source_kind='checkpoint'
  note "watermark $watermark (from the restored checkpoint; the run history was not consulted)"
fi

# The run history is the last resort, used only when nothing better supplied a watermark.
if [ -z "$watermark" ]; then
  page=1
  while [ "$page" -le "$MAX_PAGES" ]; do
    body=$(fetch_page "$page")
    pages="$page"

    count=$(printf '%s' "$body" | jq '(.workflow_runs // []) | length')
    scanned=$((scanned + count))

    # Pages are newest-first, but `max` is used rather than trusting the order within a
    # page, so a reordered page cannot yield an older watermark than one already seen.
    found=$(printf '%s' "$body" | jq -r \
      --arg branch "$BRANCH" \
      --arg exclude "$EXCLUDE_RUN_ID" '
        [ .workflow_runs[]?
          | select(.conclusion == "success")
          | select($branch == "" or $branch == "*" or .head_branch == $branch)
          | select($exclude == "" or (.id | tostring) != $exclude)
          | .created_at ]
        | max // ""')

    if [ -n "$found" ]; then
      watermark="$found"
      source_kind='last-success'
      note "watermark $watermark (successful run found on page $page, after scanning $scanned run(s))"
      break
    fi

    if [ "$count" -lt "$PER_PAGE" ]; then
      exhausted=true
      break
    fi

    note "no successful run on page $page ($count run(s) scanned, continuing)"
    page=$((page + 1))
  done
fi

if [ -z "$watermark" ]; then
  if [ "$exhausted" = true ]; then
    # The whole history is accounted for: nothing has ever succeeded.
    if [ -n "$INITIAL_WINDOW" ]; then
      start_epoch=$(resolve_start_spec "$INITIAL_WINDOW" 'INITIAL_WINDOW')
      watermark=$(from_epoch "$start_epoch")
      source_kind='initial-window'
      warn "no run of $WORKFLOW has ever succeeded; starting from INITIAL_WINDOW=$INITIAL_WINDOW ($watermark). This is expected only on a brand-new workflow."
    else
      die "no run of $WORKFLOW has ever succeeded (scanned the entire history, $scanned run(s)). Refusing to guess a window, because a guess silently skips everything before it. Set the initial-window input to start from a bounded first window, or pass override-start-time."
    fi
  else
    die "no successful run of $WORKFLOW found in the most recent $scanned run(s) ($pages page(s)). The window cannot be bounded, so this is failing rather than narrowing it and skipping events. Raise the max-pages input, or re-run with override-start-time once the cause is understood."
  fi
fi

# --- derive the window -----------------------------------------------------

start_epoch=$(to_epoch "$watermark") || die "could not parse the resolved watermark: '$watermark'"
from_epoch_value=$((start_epoch - OVERLAP_SECONDS))
from=$(from_epoch "$from_epoch_value")
to=$(from_epoch "$NOW")

age_seconds=$((NOW - start_epoch))
age_hours=$((age_seconds / 3600))
if [ "$age_seconds" -lt 0 ]; then
  # Only reachable via clock skew or a deliberately future override. Reported rather
  # than clamped, because silently moving the boundary is what hides bugs.
  warn "the watermark $watermark is $(( -age_seconds ))s in the FUTURE relative to now ($to). The window is empty; check for clock skew or a bad override-start-time."
  age_hours=0
fi

is_catchup=false
if [ "$age_hours" -ge "$WIDE_WINDOW_HOURS" ]; then
  is_catchup=true
  warn "the window is ${age_hours}h wide (from $from). This run is catching up after a gap; expect more entries than usual."
fi

emit() {
  printf '%s=%s\n' "$1" "$2"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    printf '%s=%s\n' "$1" "$2" >> "$GITHUB_OUTPUT"
  fi
}

emit source "$source_kind"
emit watermark "$watermark"
emit from "$from"
emit from-epoch "$from_epoch_value"
emit from-ms "$((from_epoch_value * 1000))"
emit to "$to"
emit to-epoch "$NOW"
emit to-ms "$((NOW * 1000))"
emit age-hours "$age_hours"
emit age-seconds "$age_seconds"
emit is-catchup "$is_catchup"
emit runs-scanned "$scanned"
emit pages-scanned "$pages"

note "window: $from -> $to (${age_hours}h wide, source=$source_kind)"
