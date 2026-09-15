#! /usr/bin/env bash
#
# Commit a checkpoint recording where this run got to.
#
# Call this only AFTER the work is done. Committing before the fan-out completes turns a
# crash into lost events; committing after turns it into re-delivered ones. That makes the
# guarantee AT-LEAST-ONCE, not exactly-once: this removes the systematic duplicates caused
# by re-reading an overlap, it does not remove the need for an idempotent sink.
#
#   CHECKPOINT_FILE       path to write                                  (required)
#   TIMESTAMP             high-water mark from the drained DATA          (recommended)
#   CURSOR                stream position, if the API has a durable one  (optional)
#   PAGE                  page number, for append-at-end feeds only      (optional)
#   SEEN_IDS_FILE         file of newline-separated ids acted on         (optional)
#   SEEN_IDS              newline-separated ids acted on                 (optional)
#   SEEN_WINDOW_SECONDS   how long to remember an id                     (default 60)
#   ALLOW_REWIND          accept a timestamp older than the stored one   (default false)
#
# Why SEEN_WINDOW_SECONDS should equal the caller's overlap, and why that is provably
# enough: an item with data timestamp T is acted on at a mark M >= T. The next window
# re-reads items with timestamp >= M' - overlap, for the new mark M'. Any item the overlap
# re-delivers therefore has T >= M' - overlap, so the mark it was recorded under satisfies
# M >= M' - overlap, i.e. M' - M <= overlap. Retaining ids while M' - M <= the window
# covers every re-delivered item exactly, with nothing kept longer than necessary. That is
# why this list stays small, instead of being time-boxed to an arbitrary many hours.
#
set -euo pipefail

CHECKPOINT_FILE="${CHECKPOINT_FILE:?CHECKPOINT_FILE is required}"
TIMESTAMP="${TIMESTAMP:-}"
CURSOR="${CURSOR:-}"
PAGE="${PAGE:-}"
SEEN_IDS_FILE="${SEEN_IDS_FILE:-}"
SEEN_IDS="${SEEN_IDS:-}"
SEEN_WINDOW_SECONDS="${SEEN_WINDOW_SECONDS:-60}"
ALLOW_REWIND="${ALLOW_REWIND:-false}"
RUN_ID="${GITHUB_RUN_ID:-}"
RUN_ATTEMPT="${GITHUB_RUN_ATTEMPT:-}"
NOW_EPOCH="${NOW_EPOCH:-}"

die() { echo "::error::$*" >&2; exit 1; }
note() { echo "$*" >&2; }
warn() { echo "::warning::$*" >&2; }

if [[ ! "$SEEN_WINDOW_SECONDS" =~ ^[0-9]+$ ]]; then
  die "SEEN_WINDOW_SECONDS must be a non-negative integer: got '$SEEN_WINDOW_SECONDS'"
fi

if [ -n "$PAGE" ] && [[ ! "$PAGE" =~ ^[0-9]+$ ]]; then
  die "PAGE must be a non-negative integer: got '$PAGE'"
fi

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

NOW=$(date -u +%s)
if [ -n "$NOW_EPOCH" ]; then
  if [[ ! "$NOW_EPOCH" =~ ^[0-9]+$ ]]; then
    die "NOW_EPOCH must be epoch seconds: got '$NOW_EPOCH'"
  fi
  NOW="$NOW_EPOCH"
fi

mkdir -p "${CHECKPOINT_FILE%/*}"

# --- the previous checkpoint, if any ---------------------------------------

prev_timestamp=''
prev_seen='[]'
prev_run=''
if [ -f "$CHECKPOINT_FILE" ] && jq -e . "$CHECKPOINT_FILE" >/dev/null 2>&1; then
  prev_timestamp=$(jq -r '.timestamp // ""' "$CHECKPOINT_FILE")
  prev_seen=$(jq -c '(.seen // []) | map(select(.id != null and .atEpoch != null))' "$CHECKPOINT_FILE")
  prev_run=$(jq -r 'if .runId == null then "" else "\(.runId)-\(.runAttempt // "")" end' "$CHECKPOINT_FILE")
fi

# Committing twice in one run attempt is worth saying out loud, because the second commit
# reaches the FILE but cannot reach the cache: entries are immutable, and both saves derive
# the same key from the same namespace, run id and attempt. The next run would then restore
# the FIRST commit and quietly re-read everything after it. Give it its own namespace, or
# commit once at the end.
if [ -n "$prev_run" ] && [ -n "$RUN_ID" ] && [ "$prev_run" = "$RUN_ID-$RUN_ATTEMPT" ]; then
  warn "this run already committed a checkpoint. The file will be updated, but the cache entry for this run cannot be rewritten, so the next run would restore the earlier commit. Commit once per run, or give this step its own checkpoint-namespace."
fi

# --- settle the timestamp, guarding against a rewind -----------------------

rewound='false'
effective_timestamp="$TIMESTAMP"

if [ -n "$TIMESTAMP" ]; then
  new_epoch=$(to_epoch "$TIMESTAMP") || die "TIMESTAMP is not a parseable timestamp: got '$TIMESTAMP'"
  if [ -n "$prev_timestamp" ]; then
    prev_epoch=$(to_epoch "$prev_timestamp") || prev_epoch=''
    if [ -n "$prev_epoch" ] && [ "$new_epoch" -lt "$prev_epoch" ]; then
      if [ "$ALLOW_REWIND" = 'true' ]; then
        warn "the checkpoint is being rewound from $prev_timestamp to $TIMESTAMP because allow-rewind is set. Everything between will be re-read."
        rewound='true'
      else
        warn "refusing to move the checkpoint backwards, from $prev_timestamp to $TIMESTAMP. A later batch that happens to contain older records must not rewind the mark, or the window would re-read on every run. Keeping $prev_timestamp. Set allow-rewind if a rewind is genuinely intended."
        effective_timestamp="$prev_timestamp"
      fi
    fi
  fi
fi

if [ -z "$effective_timestamp" ]; then
  # No mark from the caller. Inheriting the stored one is safe (the next window re-reads
  # from there); inventing "now" would skip everything the drain has not reported.
  effective_timestamp="$prev_timestamp"
  if [ -n "$prev_timestamp" ]; then
    warn "no timestamp was supplied, so the stored mark $prev_timestamp is kept. The next run re-reads from there."
  fi
fi

mark_epoch="$NOW"
if [ -n "$effective_timestamp" ]; then
  mark_epoch=$(to_epoch "$effective_timestamp") || die "the stored timestamp is unparseable: '$effective_timestamp'"
fi

# --- what kind of checkpoint is this --------------------------------------

kind='timestamp'
if [ -n "$CURSOR" ]; then
  kind='cursor'
fi
if [ -z "$CURSOR" ] && [ -n "$PAGE" ]; then
  kind='page'
fi

if [ "$kind" = 'timestamp' ] && [ -z "$effective_timestamp" ]; then
  die "nothing to record: pass a timestamp, a cursor or a page. Without any of them the next run cannot resume, and would silently re-read from the run history."
fi

if [ "$kind" != 'timestamp' ] && [ -z "$effective_timestamp" ]; then
  warn "recording a $kind with no timestamp. If this checkpoint is lost - the cache evicts after 7 idle days - there is no time-based recovery path. Pass a timestamp as well."
fi

if [ -n "$CURSOR" ] && [ -n "$PAGE" ]; then
  note "both a cursor and a page were supplied; the cursor wins, as it is the more precise position"
fi

# --- merge and prune the seen ids ----------------------------------------

NEW_IDS_FILE="${CHECKPOINT_FILE%/*}/.incoming-ids"
: > "$NEW_IDS_FILE"
if [ -n "$SEEN_IDS_FILE" ] && [ -f "$SEEN_IDS_FILE" ]; then
  cat "$SEEN_IDS_FILE" >> "$NEW_IDS_FILE"
fi
if [ -n "$SEEN_IDS" ]; then
  printf '%s\n' "$SEEN_IDS" >> "$NEW_IDS_FILE"
fi

mark_iso="$effective_timestamp"
if [ -z "$mark_iso" ]; then
  mark_iso=$(from_epoch "$mark_epoch")
fi

# jq reads the file directly and drops blank lines itself. Piping `grep -v` into it
# looks equivalent but is not: grep exits 1 when it matches nothing, pipefail turns that
# into a failed pipeline, and the `|| echo` fallback then APPENDS a second value - so the
# variable ends up holding "[]\n[]", which is not valid JSON.
incoming=$(jq -R -s -c \
  --arg at "$mark_iso" --argjson atEpoch "$mark_epoch" \
  'split("\n") | map(select(length > 0)) | map({id: ., at: $at, atEpoch: $atEpoch})' \
  < "$NEW_IDS_FILE")
incoming_count=$(printf '%s' "$incoming" | jq 'length')

cutoff=$((mark_epoch - SEEN_WINDOW_SECONDS))
merged=$(jq -n -c \
  --argjson prev "$prev_seen" \
  --argjson new "$incoming" \
  --argjson cutoff "$cutoff" '
    ($prev + $new)
    | group_by(.id)
    | map(max_by(.atEpoch))
    | map(select(.atEpoch >= $cutoff))
    | sort_by(.atEpoch)')
merged_count=$(printf '%s' "$merged" | jq 'length')
prev_count=$(printf '%s' "$prev_seen" | jq 'length')
pruned=$((prev_count + incoming_count - merged_count))
if [ "$pruned" -lt 0 ]; then
  pruned=0
fi

# --- write it, atomically -------------------------------------------------

COMMITTED_AT=$(from_epoch "$NOW")
TMP="$CHECKPOINT_FILE.tmp.$$"
jq -n \
  --arg kind "$kind" \
  --arg cursor "$CURSOR" \
  --arg page "$PAGE" \
  --arg timestamp "$effective_timestamp" \
  --arg committedAt "$COMMITTED_AT" \
  --arg runId "$RUN_ID" \
  --arg runAttempt "$RUN_ATTEMPT" \
  --argjson seen "$merged" '
    {
      kind: $kind,
      cursor: (if $cursor == "" then null else $cursor end),
      page: (if $page == "" then null else ($page | tonumber) end),
      timestamp: (if $timestamp == "" then null else $timestamp end),
      committedAt: $committedAt,
      runId: $runId,
      runAttempt: $runAttempt,
      seen: $seen
    }' > "$TMP"
mv "$TMP" "$CHECKPOINT_FILE"
rm -f "$NEW_IDS_FILE"

emit() {
  printf '%s=%s\n' "$1" "$2"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    printf '%s=%s\n' "$1" "$2" >> "$GITHUB_OUTPUT"
  fi
}

emit checkpoint-kind "$kind"
emit timestamp "$effective_timestamp"
emit cursor "$CURSOR"
emit page "$PAGE"
emit seen-ids-count "$merged_count"
emit seen-ids-pruned "$pruned"
emit rewound "$rewound"
emit checkpoint-file "$CHECKPOINT_FILE"

note "committed checkpoint: kind=$kind timestamp=${effective_timestamp:-none} seen=$merged_count (+$incoming_count new, -$pruned pruned)"
