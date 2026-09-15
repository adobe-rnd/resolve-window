#! /usr/bin/env bash
#
# Derive the checkpoint file path and cache key prefix.
#
# Both the restore side (the root action) and the save side must arrive at the SAME values
# from the same inputs, or a run would restore one checkpoint and commit another. Deriving
# them in one script, used by both, is what keeps them in step.
#
#   NAMESPACE                 explicit namespace, or empty to derive from the workflow
#   CHECKPOINT_FILE_OVERRIDE  an explicit file path, which also fixes the directory
#
# Outputs: dir, file, key-prefix, namespace
#
set -euo pipefail

NAMESPACE="${NAMESPACE:-}"
CHECKPOINT_FILE_OVERRIDE="${CHECKPOINT_FILE_OVERRIDE:-}"

if [ -z "$NAMESPACE" ]; then
  # The workflow file name, so two scheduled workflows in one repository cannot share a
  # position. GITHUB_WORKFLOW_REF looks like owner/repo/.github/workflows/x.yml@refs/...
  ref="${GITHUB_WORKFLOW_REF%%@*}"
  NAMESPACE="${ref##*/}"
fi

# Anything outside this set would break either the cache key or the path.
NAMESPACE=$(printf '%s' "$NAMESPACE" | tr -c 'a-zA-Z0-9_-' '-')

if [ -z "$NAMESPACE" ]; then
  echo "::error::could not derive a checkpoint namespace; pass checkpoint-namespace explicitly" >&2
  exit 1
fi

BASE="${RUNNER_TEMP:-/tmp}/resolve-window/$NAMESPACE"
mkdir -p "$BASE"

emit() {
  printf '%s=%s\n' "$1" "$2"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    printf '%s=%s\n' "$1" "$2" >> "$GITHUB_OUTPUT"
  fi
}

FILE="$BASE/checkpoint.json"
if [ -n "$CHECKPOINT_FILE_OVERRIDE" ]; then
  FILE="$CHECKPOINT_FILE_OVERRIDE"
  BASE="${FILE%/*}"
  mkdir -p "$BASE"
fi

emit namespace "$NAMESPACE"
emit dir "$BASE"
emit file "$FILE"
emit key-prefix "resolve-window-$NAMESPACE"
