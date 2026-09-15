#! /usr/bin/env bash
#
# Checks that the action definitions and the shell scripts still agree about their
# interfaces. Covers both action.yml (restore + resolve) and save/action.yml (commit).
#
# Every mismatch below is SILENT at runtime, which is why it gets a test rather than being
# left to review:
#   - an output wired to a step id that does not exist    -> caller reads an empty string
#   - an output wired to a step-output name nothing emits -> caller reads an empty string
#   - a declared output with no value at all              -> caller reads an empty string
#   - an env var set that no script reads                 -> setting the input does nothing
#   - an input declared but never referenced              -> setting it does nothing
#
# Parsed with grep/sed rather than a YAML library so the suite needs nothing installed.
# The parsing is deliberately strict about indentation: if an action file is reformatted,
# this test should fail loudly rather than quietly stop checking anything.
#
# What it does NOT prove: that each env var is read by the specific script of the step that
# sets it. The checks below are union-based across all scripts in the repository. The
# per-step wiring is covered by the integration job, which runs the actions for real.
#
# Usage: tests/action-contract.test.sh

TESTS_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$TESTS_DIR/.." && pwd)

pass=0
fail=0

ok() { pass=$((pass + 1)); printf '    ok    %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '    FAIL  %s\n         %s\n' "$1" "$2"; }

WORK=$(mktemp -d)

# --- what the scripts provide ----------------------------------------------

# Every `emit <name>` across every script: the set of step-output names that can exist.
grep -hE '^emit [a-z-]+ ' "$ROOT"/*.sh | awk '{print $2}' | sort -u > "$WORK/emitted"

# Every top-level assignment: a superset of the environment the scripts read.
grep -hoE '^[A-Z_]+=' "$ROOT"/*.sh | sed 's/=$//' | sort -u > "$WORK/script-vars"

echo "action contracts"
echo "  scripts emit $(grep -c . "$WORK/emitted") distinct output name(s)"

check_action() {
  local label="$1" file="$2"

  if [ ! -f "$file" ]; then
    bad "$label: the action file exists" "missing $file"
    return
  fi

  # Step ids declared in the runs block.
  sed -n '/^runs:/,$p' "$file" | grep -E '^    - id: ' | sed -E 's/^    - id: //' | sort -u > "$WORK/step-ids"

  # Declared output names.
  sed -n '/^outputs:/,/^runs:/p' "$file" | grep -E '^  [a-z][a-z0-9-]*:' | sed -E 's/^  ([a-z0-9-]+):.*/\1/' | sort -u > "$WORK/out-names"

  # Declared input names.
  sed -n '/^inputs:/,/^outputs:/p' "$file" | grep -E '^  [a-z][a-z0-9-]*:' | sed -E 's/^  ([a-z0-9-]+):.*/\1/' | sort -u > "$WORK/in-names"

  # Every `value:` reference, as "stepid name".
  grep -oE 'steps\.[a-z-]+\.outputs\.[a-z-]+' "$file" \
    | sed -E 's/steps\.([a-z-]+)\.outputs\.([a-z-]+)/\1 \2/' | sort -u > "$WORK/wiring"

  # 1. every declared output carries a value
  local declared_count value_count
  declared_count=$(grep -c . "$WORK/out-names")
  value_count=$(sed -n '/^outputs:/,/^runs:/p' "$file" | grep -cE '^    value: ')
  if [ "$declared_count" = "$value_count" ]; then
    ok "$label: all $declared_count outputs carry a value"
  else
    bad "$label: all outputs carry a value" "$declared_count declared but $value_count value: lines"
  fi

  # 2. every wired step id exists
  local bad_ids=''
  while read -r sid _; do
    [ -n "$sid" ] || continue
    if ! grep -qx "$sid" "$WORK/step-ids"; then
      bad_ids="$bad_ids $sid"
    fi
  done < "$WORK/wiring"
  if [ -z "$bad_ids" ]; then
    ok "$label: every output is wired to a step that exists"
  else
    bad "$label: every output is wired to a step that exists" "unknown step id(s):$bad_ids"
  fi

  # 3. every wired output name is emitted by some script
  local bad_names=''
  while read -r _ oname; do
    [ -n "$oname" ] || continue
    if ! grep -qx "$oname" "$WORK/emitted"; then
      bad_names="$bad_names $oname"
    fi
  done < "$WORK/wiring"
  if [ -z "$bad_names" ]; then
    ok "$label: every wired output name is emitted by a script"
  else
    bad "$label: every wired output name is emitted by a script" "never emitted:$bad_names"
  fi

  # 4. inputs are referenced, and references are declared
  grep -oE 'inputs\.[a-z-]+' "$file" | sed -E 's/inputs\.//' | sort -u > "$WORK/in-refs"
  local unused
  unused=$(comm -23 "$WORK/in-names" "$WORK/in-refs")
  if [ -z "$unused" ]; then
    ok "$label: every declared input is referenced"
  else
    bad "$label: every declared input is referenced" "declared but unused: $(printf '%s' "$unused" | tr '\n' ' ')"
  fi

  local undeclared
  undeclared=$(comm -13 "$WORK/in-names" "$WORK/in-refs")
  if [ -z "$undeclared" ]; then
    ok "$label: every referenced input is declared"
  else
    bad "$label: every referenced input is declared" "referenced but not declared: $(printf '%s' "$undeclared" | tr '\n' ' ')"
  fi

  # 5. every env var the action sets is read by some script
  sed -n '/^runs:/,$p' "$file" | grep -E '^        [A-Z_]+:' | sed -E 's/^        ([A-Z_]+):.*/\1/' | sort -u > "$WORK/action-env"
  local unread
  unread=$(comm -23 "$WORK/action-env" "$WORK/script-vars")
  if [ -z "$unread" ]; then
    ok "$label: every environment variable it sets is read by a script"
  else
    bad "$label: every environment variable it sets is read by a script" "set but never read: $(printf '%s' "$unread" | tr '\n' ' ')"
  fi

  # 6. test-only hooks must not be reachable from a workflow
  local hook
  for hook in RUNS_FIXTURE_DIR NOW_EPOCH; do
    if grep -qx "$hook" "$WORK/action-env"; then
      bad "$label: the test-only hook $hook is not exposed" \
        "$hook is set in $file, which would let a caller stub the run history or the clock"
    else
      ok "$label: the test-only hook $hook is not exposed"
    fi
  done

  # 7. every script the action invokes exists at the path it uses
  local missing=''
  local rel
  for rel in $(grep -oE 'GITHUB_ACTION_PATH/[^"]+\.sh' "$file" | sed 's|GITHUB_ACTION_PATH/||' | sort -u); do
    local resolved
    resolved=$(cd "$(dirname "$file")" && cd "$(dirname "$rel")" 2>/dev/null && pwd)/$(basename "$rel")
    if [ ! -f "$resolved" ]; then
      missing="$missing $rel"
    fi
  done
  if [ -z "$missing" ]; then
    ok "$label: every script it invokes exists"
  else
    bad "$label: every script it invokes exists" "not found:$missing"
  fi
}

check_action 'action.yml' "$ROOT/action.yml"
check_action 'save/action.yml' "$ROOT/save/action.yml"

# --- cross-cutting ---------------------------------------------------------

# The two sides must derive the checkpoint location the same way, which is only guaranteed
# because they call the same script. If one ever inlined the logic, they could drift apart
# and a run would restore one file while committing another.
root_uses=$(grep -c 'checkpoint-paths.sh' "$ROOT/action.yml")
save_uses=$(grep -c 'checkpoint-paths.sh' "$ROOT/save/action.yml")
if [ "$root_uses" -ge 1 ] && [ "$save_uses" -ge 1 ]; then
  ok 'both actions derive the checkpoint location from checkpoint-paths.sh'
else
  bad 'both actions derive the checkpoint location from checkpoint-paths.sh' \
    "action.yml: $root_uses reference(s), save/action.yml: $save_uses"
fi

# The cache key must include run_attempt on BOTH sides. Cache entries are immutable, so a
# retried attempt that matched its own first attempt's key could not save, and the run
# after it would restore that partial state.
for f in "$ROOT/action.yml" "$ROOT/save/action.yml"; do
  name=${f#"$ROOT/"}
  if grep -qE 'key: .*run_id.*run_attempt' "$f"; then
    ok "$name: the cache key includes run_attempt as well as run_id"
  else
    if grep -qE 'actions/cache' "$f"; then
      bad "$name: the cache key includes run_attempt as well as run_id" \
        'the key omits run_attempt, so a retried attempt collides with its own earlier attempt'
    else
      ok "$name: no cache step to check"
    fi
  fi
done

# --- the repository's own workflows ----------------------------------------
#
# The workflows consume these actions exactly as a caller would, so a reference to an
# output that was never declared is the same silent empty string a user would get. This
# caught committed-run being emitted by the script and used by a workflow while the action
# never declared it - invisible to every other check here, because both ends were fine.

declared_outputs_of() {
  sed -n "/^outputs:/,/^runs:/p" "$1" | grep -E "^  [a-z][a-z0-9-]*:" | sed -E "s/^  ([a-z0-9-]+):.*/\\1/"
}
declared_outputs_of "$ROOT/action.yml" | sort -u > "$WORK/root-outputs"
declared_outputs_of "$ROOT/save/action.yml" | sort -u > "$WORK/save-outputs"

for wf in "$ROOT"/.github/workflows/*.yml; do
  wf_name=$(basename "$wf")

  # Map each step id to the action it uses. Workflow steps sit at six spaces, and a new
  # step begins with "      - "; anything else at eight spaces belongs to the current step.
  awk "
    /^      - / { id = \"\"; uses = \"\" }
    /^      - id: / { id = \$3 }
    /^      - uses: / { uses = \$3 }
    /^        id: / { id = \$2 }
    /^        uses: / { uses = \$2 }
    { if (id != \"\" && uses != \"\") print id, uses }
  " "$wf" | sort -u > "$WORK/step-uses"

  bad_refs=""
  checked=0
  for ref in $(grep -oE "steps\.[a-zA-Z0-9_-]+\.outputs\.[a-zA-Z0-9_-]+" "$wf" | sort -u); do
    sid=$(printf "%s" "$ref" | cut -d. -f2)
    oname=$(printf "%s" "$ref" | cut -d. -f4)

    uses=$(awk -v s="$sid" "\$1 == s { print \$2; exit }" "$WORK/step-uses")
    # No uses means a run: step setting its own output via GITHUB_OUTPUT - not ours to check.
    [ -n "$uses" ] || continue

    case "$uses" in
      ./) list="$WORK/root-outputs" ;;
      ./save) list="$WORK/save-outputs" ;;
      *) continue ;;
    esac

    checked=$((checked + 1))
    if ! grep -qx "$oname" "$list"; then
      bad_refs="$bad_refs $sid.$oname"
    fi
  done

  if [ -z "$bad_refs" ] && [ "$checked" -gt 0 ]; then
    ok "$wf_name: all $checked action-output reference(s) are declared"
  elif [ -z "$bad_refs" ]; then
    # Not a failure: released-smoke.yml pins a published tag, which may legitimately
    # differ from the working tree. Said out loud so the pass is not mistaken for coverage.
    ok "$wf_name: no local action references to check (pins a published ref)"
  else
    bad "$wf_name: every action output it reads is declared" "not declared by the action:$bad_refs"
  fi
done

echo
echo "  $pass passed, $fail failed"
rm -rf "$WORK"
[ "$fail" -eq 0 ] || exit 1
