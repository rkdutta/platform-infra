# Shared by tests/unit/run.sh and tests/e2e/run.sh. Duplicated per-repo on
# purpose (not a shared cross-repo dependency) so this repo stays cloneable
# and runnable standalone.
set -uo pipefail

TOTAL=0
PASSED=0
FAILURES=()

# check <test-id> <file:line> -- <command...>
# Runs command; on non-zero exit records the first line of its combined
# output (truncated) as the one-line cause.
check() {
  local id="$1" loc="$2"
  shift 3  # drop id, loc, and the -- separator
  TOTAL=$((TOTAL + 1))
  local out rc
  out=$("$@" 2>&1)
  rc=$?
  if [ "$rc" -eq 0 ]; then
    PASSED=$((PASSED + 1))
  else
    local firstline="${out%%$'\n'*}"
    FAILURES+=("$id :: $loc :: ${firstline:0:150}")
  fi
}

report() {
  if [ "$TOTAL" -eq 0 ]; then
    echo "PASS: 0/0 (no checks ran)"
    exit 0
  fi
  local pct=$((PASSED * 100 / TOTAL))
  if [ "$PASSED" -eq "$TOTAL" ]; then
    echo "PASS: $PASSED/$TOTAL (100%)"
    exit 0
  else
    echo "FAIL: $PASSED/$TOTAL (${pct}%)"
    for f in "${FAILURES[@]}"; do
      echo "  $f"
    done
    exit 1
  fi
}
