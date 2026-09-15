# resolve-window

Resolve the watermark for an incremental GitHub Actions job - the time of the workflow's last
successful run - and derive the processing window from it.

This is the state-handling half of a pattern that keeps getting rebuilt by hand: a cron job that
works out what it has already processed, drains a log or events API over the gap, filters the
entries, and acts on what is left. The windowing is fiddly, easy to get subtly wrong, and identical
everywhere. The drain is not, so it is deliberately left to the caller.

```yaml
on:
  schedule:
    - cron: '*/20 * * * *'
  workflow_dispatch:
    inputs:
      override_start_time:
        description: 'ISO 8601 start of the window, to recover after a long outage'
        required: false
        type: string

permissions:
  actions: read # required: the action reads this workflow's run history

jobs:
  poll:
    runs-on: ubuntu-latest
    steps:
      - uses: adobe-rnd/resolve-window@v1
        id: window
        with:
          override-start-time: ${{ inputs.override_start_time }}

      # Your API, your pagination, your filter.
      - name: Drain the log
        env:
          FROM: ${{ steps.window.outputs.from }}
          TO: ${{ steps.window.outputs.to }}
        run: ./drain.sh "$FROM" "$TO"
```

## Why not just call the API with `?status=success`

Because that filter is not dependable on a busy workflow, and it fails in the worst possible way:
quietly, with plausible-looking data.

On a workflow with roughly 28,000 runs, five identical `?status=success` requests returned
`total_count` anywhere between 716 and 12,670, serving months-stale pages. A watermark taken from
one of those answers is silently wrong, and a silently wrong watermark means silently skipped
events.

The unfiltered run list is stable and ordered newest-first, so this action pages that instead and
filters `conclusion == "success"` locally. One page is not always enough either: an outage, or a
`concurrency` group with `cancel-in-progress`, can fill 100 consecutive runs with no success. On the
workflow that motivated this, 54 of the most recent 100 runs were non-success.

This is also why `nrwl/nx-set-shas` is not a substitute. It solves a related problem, but it asks
the API the question that cannot be trusted, and it returns a commit SHA rather than a timestamp.

## The window is deliberately not exactly-once

`from` is the watermark minus `overlap-seconds` (60 by default). That re-read exists because the API
you are draining is very likely eventually consistent: an entry timestamped just before your last
run may not have been visible to it.

So **expect the window to re-deliver entries near its lower edge, and dedupe downstream.** Comparing
timestamps is not enough for that - two genuinely distinct events can share one - so key your
deduplication on something meaningful (an id, or a tuple like path plus actor plus status) and keep
a short ledger of what you have already acted on.

Removing the overlap to avoid duplicates trades a visible, fixable problem for an invisible one.
Missed events look exactly like a quiet period.

## Remembering where you got to

Everything above derives the window from **when your job ran**. That is a proxy, and it is the
weaker of the two things you could key on, because a timestamp on the clock cannot tell the
difference between "I have already handled this" and "this only just became visible to me". If your
API can tell you where you got to in its own terms, say so, and the action will use that instead:

```yaml
      - uses: adobe-rnd/resolve-window@v1
        id: window
        with:
          checkpoint: 'true'          # restore the position the last run committed
          initial-window: 1h          # used only on the very first run

      - name: Drain the log
        id: drain
        env:
          FROM: ${{ steps.window.outputs.from }}
          # Ids already acted on, so the overlap cannot cause a repeat.
          SEEN: ${{ steps.window.outputs.seen-ids-file }}
        run: ./drain.sh "$FROM" "$SEEN"

      # Only after the work actually succeeded.
      - if: success()
        uses: adobe-rnd/resolve-window/save@v1
        with:
          # The largest timestamp in what the API returned - its clock, not the runner's.
          timestamp: ${{ steps.drain.outputs.high-water-mark }}
          seen-ids: ${{ steps.drain.outputs.acted-on-ids }}
```

The mark is stored in `actions/cache`, keyed per namespace and carrying `run_attempt` as well as
`run_id`, because cache entries are immutable and a retried attempt must not collide with its own
earlier attempt.

### Which position to commit

Four things can stand for "where I got to", and they are not equally trustworthy. In descending
order of preference:

| Tier | Commit as | Use when |
| --- | --- | --- |
| A stream cursor | `cursor` | The API documents its token as valid in a **later, independent request**. |
| A timestamp from the data | `timestamp` | Almost always. The largest value of a monotonic field the API returned. |
| A page number | `page` | Only for a stable append-at-end ordering. |
| When the run happened | nothing - omit `checkpoint` | You have none of the above. This is the v1.0 behaviour. |

**A pagination token is usually not a cursor.** The qualifying test is the one in that first row, and
most tokens fail it. The AEM admin log's `nextToken` is described as a "token to pass in next call to
continue paging" - it is scoped to one query's `from`/`to`, so saving it for the next run either
fails with an opaque 400 or, worse, silently resumes inside a result set that no longer exists. When
in doubt, commit a timestamp.

A page number is ranked below a timestamp for the same reason. Log and event feeds are almost always
newest-first, and there "page 3" means something different on every request, so a saved page number
silently skips some entries and re-reads others.

**Always commit a `timestamp`, even alongside a `cursor`.** Caches are evicted after 7 idle days
and cursors expire; when the cursor is gone the action falls back to the timestamp and carries on
with a slightly wider window. Degrade to a window, never to silence.

### The overlap still exists, and the seen list is what absorbs it

Restoring a mark does not remove the eventual-consistency problem, so `from` is still the mark minus
`overlap-seconds`, and the window still re-delivers entries at its lower edge. What changes is that
the action now hands you the list of ids you already acted on, in `seen-ids-file`, so you can drop
them:

```sh
grep -vxFf "$SEEN" candidate-ids.txt > todo.txt
```

Ids are remembered for `seen-window-seconds`, and setting that to the same value as
`overlap-seconds` is exactly right rather than merely convenient: anything the overlap can
re-deliver was, by definition, recorded within one overlap of the mark. Older ids cannot come back,
so keeping them would grow the file forever for no benefit.

### What it guarantees, and what it does not

The mark is committed **after** your work, deliberately, so a crash between acting and committing
re-delivers rather than skips. This is at-least-once, and it is the right direction to fail in: a
duplicate is visible and fixable, a gap is neither.

So a checkpoint removes the *systematic* duplicates - the ones the overlap caused on every single
run - and does not remove the need for an idempotent sink.

Two further deliberate choices:

- **The save step is explicit, not a `post:` hook.** Composite actions cannot declare one, and that
  turns out to be better: the position must not advance when the drain or the fan-out failed.
  `if: success()` says so in the workflow, where a reader can see it.
- **A mark that moves backwards is refused**, with a warning, keeping the newer value. A late batch
  containing older records must not drag the mark back, or every following run re-reads the same
  span. Pass `allow-rewind: 'true'` when you genuinely mean to reprocess.

## Failure is deliberate, in two cases

There are three outcomes, and only one of them is success.

| Situation | Behaviour |
| --- | --- |
| A successful run was found | `source=last-success` |
| `override-start-time` was given | `source=override`, the run history is not read at all |
| Nothing has ever succeeded, and `initial-window` is set | `source=initial-window`, with a warning |
| Nothing has ever succeeded, and `initial-window` is not set | **fails** |
| The page cap was reached with runs still unscanned | **fails**, always |

Both failures exist because the alternative is worse. If the window cannot be bounded and the action
guessed instead, every event older than the guess would be skipped, and the run would look perfectly
clean while doing it. A red run is a much cheaper way to find out.

`initial-window` covers the one case where a default is legitimate - a brand-new workflow with no
history to consult. It does **not** rescue a page-cap failure, because there the history exists and
simply was not read far enough. Raise `max-pages`, or pass `override-start-time` once you know why.

Wiring `override-start-time` to a `workflow_dispatch` input, as in the example above, gives an
operator a way back after an outage longer than `max-pages` can cover.

## Inputs

| Input | Default | Description |
| --- | --- | --- |
| `workflow` | the calling workflow | Workflow file name whose history defines the watermark, e.g. `track.yml`. |
| `repository` | current repository | `owner/repo` to read run history from. |
| `branch` | current branch | Only count runs on this branch. `*` counts every branch. |
| `exclude-run-id` | current run | Run id to ignore, so a re-run cannot adopt itself as its own watermark. |
| `overlap-seconds` | `60` | Subtracted from the watermark to produce `from`. |
| `max-pages` | `10` | Pages of run history (100 runs each) to scan before failing. |
| `per-page` | `100` | Runs requested per page, 1 to 100. |
| `wide-window-hours` | `6` | Warn, and set `is-catchup`, at or above this width. |
| `override-start-time` | none | Skip the history and start here. Timestamp, or a duration such as `45m`. |
| `initial-window` | none | Fallback used **only** when nothing has ever succeeded. |
| `checkpoint` | `false` | Restore the position the previous run committed, and prefer it over the run history. |
| `checkpoint-namespace` | calling workflow's file name | Names the stored position. The save action must be given the same value. |
| `github-token` | `${{ github.token }}` | Token for the runs API. Needs `actions: read`. |

Durations accept `s`, `m`, `h` and `d`, as in `90s`, `45m`, `12h`, `7d`.

## Outputs

| Output | Example | Description |
| --- | --- | --- |
| `source` | `last-success` | `last-success`, `override` or `initial-window`. |
| `watermark` | `2026-09-15T09:20:00Z` | The last successful run, before the overlap. |
| `from` | `2026-09-15T09:19:00Z` | Start of the window. `watermark` minus `overlap-seconds`. |
| `from-epoch` | `1789456740` | `from` in epoch seconds. |
| `from-ms` | `1789456740000` | `from` in epoch milliseconds. |
| `to` | `2026-09-15T09:40:00Z` | End of the window, evaluated when the action ran. |
| `to-epoch` | `1789458000` | `to` in epoch seconds. |
| `to-ms` | `1789458000000` | `to` in epoch milliseconds. |
| `age-hours` | `0` | Whole hours from the watermark to now. |
| `age-seconds` | `1200` | Seconds from the watermark to now. Negative if the watermark is in the future. |
| `is-catchup` | `false` | `true` when the window is at least `wide-window-hours` wide. |
| `runs-scanned` | `2` | Runs examined. `0` for an override. |
| `pages-scanned` | `1` | Pages fetched. `0` for an override. |
| `checkpoint-kind` | `timestamp` | `cursor`, `timestamp`, `page`, or `none` when there was nothing to restore. |
| `resumable` | `true` | `true` when a position was restored. |
| `cursor` | | The stream position to resume from, if one was committed. |
| `page` | | The page to resume from, if one was committed. |
| `checkpoint-timestamp` | `2026-09-15T09:20:00Z` | The restored mark, in the API's own time domain. `from` derives from this. |
| `committed-at` | `2026-09-15T09:21:04Z` | When the restored position was committed. |
| `committed-run` | `34870679129-1` | Which run committed it, as `run_id-run_attempt`. |
| `seen-ids-file` | `/home/runner/work/_temp/...` | Newline-separated ids already acted on. Use with `grep -vxFf`. |
| `seen-ids-count` | `3` | How many ids that file holds. |
| `checkpoint-file` | `/home/runner/work/_temp/...` | Path of the checkpoint, to pass to the save action. |

When `checkpoint` is not enabled, or nothing was restored, `checkpoint-kind` is `none`,
`resumable` is `false`, and `source` reports the run-history tier as before. A missing or
malformed checkpoint is never fatal.

## The save action

`adobe-rnd/resolve-window/save@v1` commits the position. Give it the same
`checkpoint-namespace` as the restore step, or pass that step's `checkpoint-file` output to be
certain both sides address the same file.

| Input | Default | Description |
| --- | --- | --- |
| `timestamp` | none | High-water mark from the drained data. Supply this even when passing a cursor. |
| `cursor` | none | A stream position, only if the API documents it as valid in a later request. |
| `page` | none | A page number, only for a stable append-at-end ordering. |
| `seen-ids` | none | Newline-separated ids acted on in this run. |
| `seen-ids-file` | none | A file of ids acted on, as an alternative to `seen-ids`. |
| `seen-window-seconds` | `60` | How long to remember an id. Set it to `overlap-seconds`. |
| `allow-rewind` | `false` | Permit a mark older than the stored one. |
| `checkpoint-namespace` | calling workflow's file name | Must match the restore step. |
| `checkpoint-file` | derived | Explicit path, overriding the namespace. |

| Output | Example | Description |
| --- | --- | --- |
| `checkpoint-kind` | `timestamp` | Which tier was committed. |
| `timestamp` | `2026-09-15T09:40:00Z` | The mark actually committed. Differs from the input if a rewind was refused. |
| `rewound` | `false` | `true` when the mark was deliberately moved backwards. |
| `seen-ids-count` | `3` | Ids remembered after merging and pruning. |
| `seen-ids-pruned` | `1` | Ids dropped for falling outside the retention window. |
| `checkpoint-file` | `/home/runner/work/_temp/...` | Path written. |

Exactly one of `timestamp`, `cursor` or `page` is required. The step fails if you pass none,
because a save that silently did nothing would leave the next run re-reading the same span forever.

`is-catchup` is worth branching on: a catch-up window can return far more entries than a normal one,
which is often the moment a downstream fan-out hits a rate limit.

## Requirements

- `permissions: actions: read` on the calling job. Without it the runs API answers 403 and the
  action fails with that specific advice.
- `bash` and `jq`, both present on every GitHub-hosted runner. Tested on `ubuntu-latest` and
  `macos-latest`; GNU and BSD `date` are both handled.

## What this does not do

- **It does not drain your API.** Pagination, auth and time parameters differ per API - cursor
  tokens, page numbers, `Link` headers, relative durations - and wrapping that in a generic
  interface produces something harder to use than the API.
- **It does not make your sink idempotent.** With `checkpoint` enabled it remembers the ids you
  acted on for one overlap, which removes the repeats the overlap itself causes. It cannot remove the
  repeat caused by a crash between acting and committing, because the mark is committed last on
  purpose. Something downstream still has to tolerate seeing an item twice.
- **It does not fan out.** Worth knowing if you do: `repository_dispatch` and `workflow_dispatch`
  are the documented exceptions to the rule that `GITHUB_TOKEN`-triggered events do not start new
  workflow runs, so a fan-out needs no PAT.

## Tests

```sh
bash tests/resolve-window.test.sh   # 104 assertions against fixtures, with a pinned clock
bash tests/checkpoint.test.sh       #  95 assertions on restoring and committing a position
bash tests/action-contract.test.sh  #  25 checks that the YAML and the scripts still agree
```

The suite runs the real script; there is no second copy of its logic to drift out of step with it.
The run history comes from `page<N>.json` fixtures via `RUNS_FIXTURE_DIR`, and `NOW_EPOCH` pins the
clock, so no case touches the network and every expected timestamp is arithmetic.

`tests/action-contract.test.sh` guards the mistakes that are invisible at runtime: an output wired
to a step that does not exist, an output wired to a name no script emits, an environment variable set
that nothing reads, an input declared but never referenced, and - across this repository's own
workflows - a caller reading an output the action never declared. Every one of those yields an empty
string rather than an error, which is why they get a test instead of a review.

Each assertion there has been verified by breaking the thing it describes and confirming that it, and
not some other assertion, is what goes red. A contract test that has never been seen to fail is
proof of nothing.

The cross-run half of the checkpoint cannot be tested inside one job, so it is not faked: the Test
workflow uses a namespace unique per run attempt and asserts the cold-start fallback, while
`checkpoint-smoke.yml` uses a fixed namespace and advances the mark, so each run must restore what
its predecessor committed.

## Releasing

Run the **Release** workflow, choose `patch`, `minor` or `major`, and it will run the tests, smoke
test the action, compute the next version, tag it, publish release notes, and move the major alias.
`dry-run` reports the version it would cut and stops.

Consumers pin to `@v1` to follow every 1.x release, or to `@v1.2.3` for an immutable one.

Note that `uses:` cannot take an expression, so a newly cut tag cannot be exercised with
`uses: ...@<new tag>` in the run that created it. The release job verifies through the API instead
that both the version tag and the major alias resolve to the release commit and carry an
`action.yml`.

## Licence

Apache 2.0. See [LICENSE](LICENSE).
