#! /usr/bin/env bash
#
# Checks that action.yml and resolve-window.sh still agree about their interface.
#
# These mismatches are all silent at runtime, which is why they get a test:
#   - the script emits an output that action.yml never exposes, so a caller cannot read it
#   - action.yml declares an output the script never emits, so the caller reads an empty string
#   - an output is wired to the wrong step output name, so it is always empty
#   - action.yml maps an input the script does not read, so setting it does nothing
#
# Parsed with grep/sed rather than a YAML library so the suite needs nothing installed.
# The parsing is deliberately strict about indentation; if action.yml is reformatted, this
# test is expected to fail loudly rather than silently stop checking.
#
# Usage: tests/action-contract.test.sh

TESTS_DIR=$(cd "$(dirname "$0")" && pwd)
ACTION="$TESTS_DIR/../action.yml"
SCRIPT="$TESTS_DIR/../resolve-window.sh"

pass=0
fail=0

ok() {
  pass=$((pass + 1))
  printf '    ok    %s\n' "$1"
}

bad() {
  fail=$((fail + 1))
  printf '    FAIL  %s\n         %s\n' "$1" "$2"
}

for f in "$ACTION" "$SCRIPT"; do
  if [ ! -f "$f" ]; then
    echo "missing $f" >&2
    exit 1
  fi
done

echo "action.yml contract"

# --- extract ----------------------------------------------------------------

# Names declared in a top-level block, e.g. everything between `outputs:` and `runs:`.
block_keys() {
  local start="$1" end="$2"
  sed -n "/^${start}:/,/^${end}:/p" "$ACTION" \
    | grep -E '^  [a-z][a-z0-9-]*:' \
    | sed -E 's/^  ([a-z0-9-]+):.*/\1/'
}

emitted=$(grep -E '^emit [a-z-]+ ' "$SCRIPT" | awk '{print $2}' | sort -u)
declared_outputs=$(block_keys outputs runs | sort -u)
declared_inputs=$(block_keys inputs outputs | sort -u)

# `value: ${{ steps.resolve.outputs.NAME }}` -> NAME
wired=$(grep -oE 'steps\.resolve\.outputs\.[a-z-]+' "$ACTION" \
  | sed -E 's/.*outputs\.//' | sort -u)

# `${{ inputs.NAME }}` anywhere in the runs block
referenced_inputs=$(grep -oE 'inputs\.[a-z-]+' "$ACTION" \
  | sed -E 's/inputs\.//' | sort -u)

# Every top-level assignment in the script, which is where it reads its environment.
# A superset is fine here: the check below is one-directional, asserting only that
# everything action.yml sets is something the script reads.
script_vars=$(grep -oE '^[A-Z_]+=' "$SCRIPT" | sed 's/=$//' | sort -u)

# Environment variables action.yml sets for the step, e.g. `OVERLAP_SECONDS: ${{ ... }}`.
action_env=$(sed -n '/^      env:/,/^      run:/p' "$ACTION" \
  | grep -E '^        [A-Z_]+:' \
  | sed -E 's/^        ([A-Z_]+):.*/\1/' | sort -u)

echo "  script emits $(printf '%s\n' "$emitted" | grep -c .) outputs; action.yml declares $(printf '%s\n' "$declared_outputs" | grep -c .)"

# --- compare ----------------------------------------------------------------

missing_declaration=$(comm -23 <(printf '%s\n' "$emitted") <(printf '%s\n' "$declared_outputs"))
if [ -z "$missing_declaration" ]; then
  ok 'every output the script emits is declared in action.yml'
else
  bad 'every output the script emits is declared in action.yml' \
    "not declared: $(printf '%s' "$missing_declaration" | tr '\n' ' ')"
fi

never_emitted=$(comm -13 <(printf '%s\n' "$emitted") <(printf '%s\n' "$declared_outputs"))
if [ -z "$never_emitted" ]; then
  ok 'every declared output is emitted by the script'
else
  bad 'every declared output is emitted by the script' \
    "declared but never emitted: $(printf '%s' "$never_emitted" | tr '\n' ' ')"
fi

unwired=$(comm -23 <(printf '%s\n' "$declared_outputs") <(printf '%s\n' "$wired"))
if [ -z "$unwired" ]; then
  ok 'every declared output is wired to the resolve step by the same name'
else
  bad 'every declared output is wired to the resolve step by the same name' \
    "not wired, or wired to a different name: $(printf '%s' "$unwired" | tr '\n' ' ')"
fi

unused_inputs=$(comm -23 <(printf '%s\n' "$declared_inputs") <(printf '%s\n' "$referenced_inputs"))
if [ -z "$unused_inputs" ]; then
  ok 'every declared input is referenced in the runs block'
else
  bad 'every declared input is referenced in the runs block' \
    "declared but unused: $(printf '%s' "$unused_inputs" | tr '\n' ' ')"
fi

undeclared_refs=$(comm -13 <(printf '%s\n' "$declared_inputs") <(printf '%s\n' "$referenced_inputs"))
if [ -z "$undeclared_refs" ]; then
  ok 'every referenced input is declared'
else
  bad 'every referenced input is declared' \
    "referenced but not declared: $(printf '%s' "$undeclared_refs" | tr '\n' ' ')"
fi

unread_env=$(comm -23 <(printf '%s\n' "$action_env") <(printf '%s\n' "$script_vars"))
if [ -z "$unread_env" ]; then
  ok 'every environment variable action.yml sets is read by the script'
else
  bad 'every environment variable action.yml sets is read by the script' \
    "set but never read: $(printf '%s' "$unread_env" | tr '\n' ' ')"
fi

# The script must not require anything the action never provides. RUNS_FIXTURE_DIR and
# NOW_EPOCH are test-only hooks and are expected to be absent from action.yml.
for hook in RUNS_FIXTURE_DIR NOW_EPOCH; do
  if printf '%s\n' "$action_env" | grep -qx "$hook"; then
    bad "the test-only hook $hook is not exposed as an action input" \
      "$hook appears in action.yml, which would let a caller stub the run history"
  else
    ok "the test-only hook $hook is not exposed as an action input"
  fi
done

echo
echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
