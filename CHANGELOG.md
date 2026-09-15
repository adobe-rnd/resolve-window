# Changelog

All notable changes to this action are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[semantic versioning](https://semver.org/spec/v2.0.0.html).

For an action, the public interface is the set of inputs, the set of outputs, and the conditions
under which the action fails. A change that makes the action fail where it used to succeed is a
breaking change even when no input changed, because it will stop a consumer's scheduled job.

## [Unreleased]

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
