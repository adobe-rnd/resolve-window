#! /usr/bin/env bash
#
# Read a previously committed checkpoint and report the position it can resume from.
#
# A checkpoint records where the last successful run stopped, in the most precise form
# the drained API can express. The tiers, best first:
#
#   1. cursor     A stream position the API documents as valid in a LATER, INDEPENDENT
#                 request. Needs no overlap: resumption is exact.
#                 NOT the same thing as a pagination token. Most REST pagination cursors
#                 (AEM `nextToken`, "token to pass in next call to continue paging") are
#                 scoped to one query's result set and are INVALID here. If in doubt,
#                 use a timestamp: a wrong cursor fails quietly or with an opaque 400.
#   2. timestamp  The high-water mark of a monotonic field in the returned DATA. This is
#                 the workhorse tier, and it beats GitHub's run clock because it lives in
#                 the API's own time domain - immune to Actions queue delay and skew.
#   3. page       A page number. Only meaningful under a STABLE, APPEND-AT-END ordering.
#                 Log and event feeds are usually newest-first, where a saved page number
#                 silently skips and re-reads. Supported, but rarely correct.
#
# A timestamp is recorded alongside a cursor or a page whenever the caller supplies one,
# because every tier above it can be lost or invalidated - the cache evicts after 7 idle
# days, cursors expire, page numbers stop meaning anything. The timestamp is the recovery
# path, so a lost checkpoint degrades to a time window rather than to silence.
#
#   CHECKPOINT_FILE   path to the checkpoint JSON               (required)
#   GITHUB_OUTPUT     appended to when set
#
# Outputs (stdout as name=value, and $GITHUB_OUTPUT when set):
#   checkpoint-kind   cursor | timestamp | page | none
#   resumable         true when a position was restored
#   cursor            the stream position, when kind=cursor
#   page              the page number, when kind=page
#   timestamp         the high-water mark, when recorded
#   seen-ids-file     path to a newline-separated list of ids already acted on
#   seen-ids-count    how many ids that file holds
#   committed-at      when the checkpoint was written
#   committed-run     the run that wrote it
#
# A missing or malformed checkpoint is NOT an error. It reports kind=none so the caller
# falls back to the run history, which is the safe direction: re-reading a window costs a
# duplicate, while treating a bad checkpoint as authoritative would skip events silently.
#
set -euo pipefail

CHECKPOINT_FILE="${CHECKPOINT_FILE:?CHECKPOINT_FILE is required}"

note() { echo "$*" >&2; }
warn() { echo "::warning::$*" >&2; }

SEEN_FILE="${CHECKPOINT_FILE%/*}/seen-ids.txt"
: > "$SEEN_FILE"

emit() {
  printf '%s=%s\n' "$1" "$2"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    printf '%s=%s\n' "$1" "$2" >> "$GITHUB_OUTPUT"
  fi
}

emit_none() {
  emit checkpoint-kind 'none'
  emit resumable 'false'
  emit cursor ''
  emit page ''
  emit timestamp ''
  emit seen-ids-file "$SEEN_FILE"
  emit seen-ids-count '0'
  emit committed-at ''
  emit committed-run ''
}

if [ ! -f "$CHECKPOINT_FILE" ]; then
  note "no checkpoint at $CHECKPOINT_FILE; the run history will be used instead"
  emit_none
  exit 0
fi

if ! jq -e . "$CHECKPOINT_FILE" >/dev/null 2>&1; then
  warn "the checkpoint at $CHECKPOINT_FILE is not valid JSON, so it is being ignored. The run history will be used instead, which re-reads rather than skips."
  emit_none
  exit 0
fi

kind=$(jq -r '.kind // ""' "$CHECKPOINT_FILE")
cursor=$(jq -r '.cursor // ""' "$CHECKPOINT_FILE")
page=$(jq -r '.page // "" | tostring' "$CHECKPOINT_FILE")
timestamp=$(jq -r '.timestamp // ""' "$CHECKPOINT_FILE")
committed_at=$(jq -r '.committedAt // ""' "$CHECKPOINT_FILE")
committed_run=$(jq -r '.runId // ""' "$CHECKPOINT_FILE")

case "$kind" in
  cursor | timestamp | page) : ;;
  '')
    warn "the checkpoint has no kind, so it is being ignored"
    emit_none
    exit 0
    ;;
  *)
    warn "the checkpoint has an unrecognised kind '$kind', so it is being ignored"
    emit_none
    exit 0
    ;;
esac

# The recorded position must actually be present for the kind it claims. A checkpoint
# claiming kind=cursor with no cursor would otherwise resume from nothing at all.
if [ "$kind" = 'cursor' ] && [ -z "$cursor" ]; then
  warn "the checkpoint claims kind=cursor but records no cursor; falling back"
  emit_none
  exit 0
fi

if [ "$kind" = 'page' ] && [ -z "$page" ]; then
  warn "the checkpoint claims kind=page but records no page; falling back"
  emit_none
  exit 0
fi

if [ "$kind" = 'timestamp' ] && [ -z "$timestamp" ]; then
  warn "the checkpoint claims kind=timestamp but records no timestamp; falling back"
  emit_none
  exit 0
fi

# The ids already acted on, for suppressing what the overlap re-delivers. Written to a
# file rather than an output value: a caller can then use `grep -Fxf`, and there is no
# multiline-output escaping to get wrong.
jq -r '(.seen // []) | .[] | .id | select(. != null and . != "")' "$CHECKPOINT_FILE" > "$SEEN_FILE" 2>/dev/null || : > "$SEEN_FILE"
# awk rather than `grep -c . || echo 0`: grep exits 1 on a zero count, so the fallback
# would append a second number and the emitted output would hold two lines.
seen_count=$(awk 'END {print NR+0}' "$SEEN_FILE")

if [ "$kind" != 'timestamp' ] && [ -z "$timestamp" ]; then
  warn "the checkpoint records a $kind but no timestamp. If it is ever lost - the cache evicts after 7 idle days - there is no time-based recovery path and the run history will be used instead. Pass a timestamp to the save step as well."
fi

emit checkpoint-kind "$kind"
emit resumable 'true'
emit cursor "$cursor"
emit page "$page"
emit timestamp "$timestamp"
emit seen-ids-file "$SEEN_FILE"
emit seen-ids-count "$seen_count"
emit committed-at "$committed_at"
emit committed-run "$committed_run"

note "restored checkpoint: kind=$kind timestamp=${timestamp:-none} seen=$seen_count (committed $committed_at by run $committed_run)"
