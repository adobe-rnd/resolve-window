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
- **It does not keep a ledger of what you have acted on.** The overlap guarantees repeats, so
  something downstream must be idempotent. `actions/cache` with a key containing `github.run_id` and
  a `restore-keys` prefix works well for a small ledger, since cache entries cannot be overwritten.
- **It does not fan out.** Worth knowing if you do: `repository_dispatch` and `workflow_dispatch`
  are the documented exceptions to the rule that `GITHUB_TOKEN`-triggered events do not start new
  workflow runs, so a fan-out needs no PAT.

## Tests

```sh
bash tests/resolve-window.test.sh   # 104 assertions against fixtures, with a pinned clock
bash tests/action-contract.test.sh  # action.yml and the script still agree
```

The suite runs the real script; there is no second copy of its logic to drift out of step with it.
The run history comes from `page<N>.json` fixtures via `RUNS_FIXTURE_DIR`, and `NOW_EPOCH` pins the
clock, so no case touches the network and every expected timestamp is arithmetic.

`tests/action-contract.test.sh` guards the mistakes that are invisible at runtime: an output the
script emits but `action.yml` never exposes, an output declared but never emitted, or one wired to
the wrong step output name. Each of those yields an empty string to the caller rather than an error.

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
