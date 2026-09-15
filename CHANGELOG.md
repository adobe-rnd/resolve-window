# Changelog

All notable changes to this action are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[semantic versioning](https://semver.org/spec/v2.0.0.html).

For an action, the public interface is the set of inputs, the set of outputs, and the conditions
under which the action fails. A change that makes the action fail where it used to succeed is a
breaking change even when no input changed, because it will stop a consumer's scheduled job.

## [1.1.0] - 2026-09-15

Adds an optional checkpoint, so the window can be derived from a position in the drained data rather
than from the time the previous run happened. Nothing changes for existing callers: `checkpoint`
defaults to `false`, and with it off the action behaves exactly as 1.0.0 did.

### Added

- `checkpoint` and `checkpoint-namespace` inputs. With `checkpoint: true` the action restores the
  position the previous run committed and prefers it over the run history, reporting
  `source=checkpoint`. The stored position outranks `last-success` and is outranked by
  `override-start-time`.
- A `save` sub-action, `adobe-rnd/resolve-window/save@v1`, committing a `timestamp`, `cursor`
  or `page`. It is an explicit step rather than a `post:` hook, which composite actions cannot
  declare, so the position can be made conditional on the drain having succeeded.
- `seen-ids` on the save side and `seen-ids-file` on the restore side: the ids acted on are
  remembered for `seen-window-seconds`, so the entries the overlap re-delivers can be dropped
  without a downstream ledger. One overlap is provably long enough, because anything the overlap can
  re-deliver was recorded within one overlap of the mark.
- A rewind guard. A mark older than the stored one is refused with a warning, keeping the newer
  value, unless `allow-rewind` is set. Without it, one late batch of older records would make every
  following run re-read the same span.
- Outputs `checkpoint-kind`, `resumable`, `cursor`, `page`, `checkpoint-timestamp`,
  `committed-at`, `committed-run`, `seen-ids-file`, `seen-ids-count` and `checkpoint-file`.
- A warning when the same run attempt commits twice. The second commit reaches the file but not
  the cache, since both derive the same immutable key, so the next run would restore the first
  commit and re-read everything after it. Found by reading the CI log of a green run, where it
  appeared only as `Cache save failed`.
- `tests/checkpoint.test.sh`, 108 assertions on restoring and committing, and `checkpoint-smoke.yml`,
  which uses a fixed namespace and advances the mark so each run must restore what its predecessor
  committed. The in-job Test leg deliberately uses a namespace unique per run attempt, because a
  fixed one would make it restore its own previous state and its cold-start assertion would pass
  once and then fail forever.

### Changed

- `actions/cache` restore and save pinned to v6, which runs on Node 24. v4 is forced onto Node 24
  by the runner anyway and warns about it on every run.

- `tests/action-contract.test.sh` now covers both action files and, additionally, checks that this
  repository's own workflows only read outputs the actions declare. That check immediately found
  `committed-run` being emitted by the script and consumed by a workflow while the action never
  declared it - which every prior check considered fine, since both ends were individually correct.
- The cache key on both sides carries `run_attempt` as well as `run_id`. Cache entries are
  immutable, so a retried attempt keyed on `run_id` alone would hit its own first attempt's
  partial state and then be unable to save.

### Notes

- A checkpoint makes delivery at-least-once, not exactly-once. The mark is committed after the work,
  so a crash in between re-delivers rather than skips. It removes the repeats the overlap caused on
  every run; it does not remove the need for an idempotent sink.
- A missing, malformed or evicted checkpoint is never fatal: the action reports
  `checkpoint-kind=none` and falls back to the run history. Cache entries are evicted after 7 idle
  days, so this is a normal event, not an error.
- A pagination token is usually not a stream cursor. The qualifying test is whether the API documents
  it as valid in a later, independent request; tokens scoped to one query's result set, such as the
  AEM admin log's `nextToken`, are not, and fail opaquely if saved. Commit a timestamp instead.

## [1.0.0] - 2026-09-15

### Added

- `resolve-window.sh` and a composite action wrapping it, resolving the watermark from the last
  successful run of a workflow and deriving the processing window.
- Local paging of the run history, rather than `?status=success`, which is not dependable on a
  high-volume workflow.
- `override-start-time` for operator recovery, accepting a timestamp or a duration.
- `initial-window` for the cold start on a workflow that has never succeeded.
- `is-catchup` and a warning when the window is unusually wide.
- Test suite of 104 assertions against run-history fixtures with a pinned clock, plus a contract
  test that `action.yml` and the script still agree about inputs and outputs.
- CI on `ubuntu-latest` and `macos-latest`, so the BSD `date` fallback is exercised rather than
  merely present.
