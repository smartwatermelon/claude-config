#!/usr/bin/env bats
# Tests for the byte-aware diff gate in pre-merge-review.sh (issue #612)
#
# Bug: the "include the full diff" gate counted LINES only. A PR adding a
# generated single-line JSON file (1.2 MB on one line) was "567 lines, under
# threshold", so the whole diff went into the prompt. The prompt was
# 1,758,974 bytes (~1.4M tokens), the Claude CLI rejected it, and the merge
# failed with a valid lock and green CI. The PR was then merged in the web
# UI, which skips pre-merge review entirely.
#
# Fix: build_targeted_diff() gates on bytes as well as lines, and on the smart
# path elides any file diff over a per-file (or running-total) byte cap,
# replacing it with a stub that says the content was NOT reviewed. The review
# still runs on everything else.
#
# Run: bats ~/.claude/tests/test_pre_merge_diff_bytes.bats

bats_require_minimum_version 1.5.0

SCRIPT="${BATS_TEST_DIRNAME:-}/../hooks/pre-merge-review.sh"
LIB="${BATS_TEST_DIRNAME:-}/../hooks/lib-review-issues.sh"

log_info() { echo "INFO: $*" >>"${LOG_FILE}"; }
log_warn() { echo "WARN: $*" >>"${LOG_FILE}"; }
log_error() { echo "ERROR: $*" >>"${LOG_FILE}"; }
log_success() { :; }

export LOG_FILE=""

setup() {
  MOCK_DIR="$(mktemp -d)"
  export MOCK_DIR
  LOG_FILE="${MOCK_DIR}/log.txt"
  : >"${LOG_FILE}"
}

teardown() {
  rm -rf "${MOCK_DIR}"
}

# Same helper as the other pre-merge tests: the sed range stops at the first
# bare `}` on its own line.
_load_fn() {
  local file="$1" fn_name="$2"
  local func_def
  func_def=$(sed -n "/^${fn_name}()/,/^}$/p" "${file}")
  [[ -n "${func_def}" ]] || {
    echo "function ${fn_name} not found in ${file}" >&2
    return 1
  }
  eval "${func_def}"
}

# Load the gate and everything it calls. Constants come from the script itself
# so the tests exercise the shipped values.
_load_gate() {
  DIFF_LINE_THRESHOLD=$(_const DIFF_LINE_THRESHOLD)
  DIFF_BYTE_BUDGET=$(_const DIFF_BYTE_BUDGET)
  DIFF_FILE_BYTE_CAP=$(_const DIFF_FILE_BYTE_CAP)
  DIFF_BYTE_TOTAL_CAP=$(_const DIFF_BYTE_TOTAL_CAP)
  [[ -n "${DIFF_LINE_THRESHOLD}" && -n "${DIFF_BYTE_BUDGET}" ]]
  [[ -n "${DIFF_FILE_BYTE_CAP}" && -n "${DIFF_BYTE_TOTAL_CAP}" ]]
  local fn
  for fn in _byte_len summarize_oversized_file build_targeted_diff \
    extract_file_diff get_changed_files is_data_file has_inline_comments \
    summarize_data_file truncate_code_diff; do
    _load_fn "${SCRIPT}" "${fn}"
  done
  _load_fn "${LIB}" is_security_critical
  export COMMENTED_FILES=""
  export REQUIRED_CHECKS=""
  TARGETED_DIFF=""
}

# Read a numeric constant from the script.
_const() {
  sed -n "s/^$1=\([0-9][0-9]*\)$/\1/p" "${SCRIPT}"
}

# A small, ordinary code change.
_code_diff() {
  cat <<'EOF'
diff --git a/src/app.js b/src/app.js
index 1111111..2222222 100644
--- a/src/app.js
+++ b/src/app.js
@@ -1,3 +1,4 @@
 const a = 1;
+const marker = "CODE_CHANGE_MARKER";
 const b = 2;
 module.exports = { a, b };
EOF
}

# A new file whose whole content is ONE line of $2 bytes.
_one_line_file_diff() {
  local path="$1" bytes="$2"
  printf 'diff --git a/%s b/%s\n' "${path}" "${path}"
  printf 'new file mode 100644\nindex 0000000..3333333\n'
  printf -- '--- /dev/null\n+++ b/%s\n@@ -0,0 +1 @@\n' "${path}"
  printf '+{"d":"'
  # Via a file, not a pipe: bash string ops on a megabyte are quadratic.
  head -c "${bytes}" /dev/zero >"${MOCK_DIR}/zeros"
  tr '\0' 'x' <"${MOCK_DIR}/zeros"
  printf '"}\n'
}

# Build PR_DIFF from the code diff plus any extra one-line files.
# Args: pairs of <path> <bytes>
_set_pr_diff() {
  {
    _code_diff
    while [[ $# -ge 2 ]]; do
      _one_line_file_diff "$1" "$2"
      shift 2
    done
  } >"${MOCK_DIR}/pr.diff"
  PR_DIFF="$(<"${MOCK_DIR}/pr.diff")"
}

# Assert TARGETED_DIFF is smaller than $1 bytes.
_assert_targeted_under() {
  local n
  n=$(_byte_count "${TARGETED_DIFF}")
  ((n < $1))
}

_byte_count() {
  local n
  n=$(printf '%s' "$1" | wc -c)
  echo "$((n))"
}

# --- Constants ---

@test "constants: script defines the line threshold and byte caps" {
  grep -qE '^DIFF_LINE_THRESHOLD=1000$' "${SCRIPT}"
  grep -qE '^DIFF_BYTE_BUDGET=[0-9]+$' "${SCRIPT}"
  grep -qE '^DIFF_FILE_BYTE_CAP=[0-9]+$' "${SCRIPT}"
  grep -qE '^DIFF_BYTE_TOTAL_CAP=[0-9]+$' "${SCRIPT}"
}

# --- Normal diff: unchanged behavior ---

@test "normal diff: included byte-for-byte, logged as under threshold" {
  _load_gate
  PR_DIFF="$(_code_diff)"
  build_targeted_diff
  [[ "${TARGETED_DIFF}" == "${PR_DIFF}" ]]
  grep -q "under threshold" "${LOG_FILE}"
  [[ "${TARGETED_DIFF}" != *"ELIDED"* ]]
}

# --- The #612 case: a huge single-line file in a short diff ---

@test "huge one-line file: elided, code change kept in full, output bounded" {
  _load_gate
  _set_pr_diff data/climate.json 1245090
  # The regression precondition: few lines, many bytes.
  local lines
  lines=$(wc -l <"${MOCK_DIR}/pr.diff")
  ((lines < DIFF_LINE_THRESHOLD))

  build_targeted_diff

  # Elided with an explicit not-reviewed stub naming the file.
  grep -q "ELIDED: diff too large to include" <<<"${TARGETED_DIFF}"
  grep -q "File: data/climate.json" <<<"${TARGETED_DIFF}"
  grep -q "Files ELIDED for size (NOT reviewed): 1" <<<"${TARGETED_DIFF}"
  # The code change survives verbatim.
  grep -qF '+const marker = "CODE_CHANGE_MARKER";' <<<"${TARGETED_DIFF}"
  # And the result is far below the budget, not 1.2 MB.
  _assert_targeted_under "${DIFF_BYTE_BUDGET}"
  grep -q "Elided 1 oversized" "${LOG_FILE}"
}

@test "huge one-line file: elided even with green CI (no CI-trust shortcut)" {
  _load_gate
  REQUIRED_CHECKS="tests: SUCCESS"
  _set_pr_diff data/era5.json 480423
  build_targeted_diff
  grep -q "ELIDED: diff too large to include" <<<"${TARGETED_DIFF}"
  # Not mislabelled as a CI-validated data file.
  [[ "${TARGETED_DIFF}" != *"CI validated data file"* ]]
}

@test "huge one-line security-critical file: still elided (size check runs first)" {
  _load_gate
  local path=".env.production.secrets"
  is_security_critical "${path}"
  _set_pr_diff "${path}" 300000
  build_targeted_diff
  grep -q "File: ${path}" <<<"${TARGETED_DIFF}"
  grep -q "ELIDED: diff too large to include" <<<"${TARGETED_DIFF}"
  _assert_targeted_under "${DIFF_BYTE_BUDGET}"
}

@test "many mid-sized files: running total cap elides the overflow" {
  _load_gate
  # Each file is under the per-file cap; together they exceed the total cap.
  _set_pr_diff gen/p1.txt 90000 gen/p2.txt 90000 gen/p3.txt 90000 \
    gen/p4.txt 90000 gen/p5.txt 90000 gen/p6.txt 90000 gen/p7.txt 90000 \
    gen/p8.txt 90000
  build_targeted_diff
  grep -q "total cap" <<<"${TARGETED_DIFF}"
  grep -qF '+const marker = "CODE_CHANGE_MARKER";' <<<"${TARGETED_DIFF}"
  _assert_targeted_under $((DIFF_BYTE_TOTAL_CAP + 50000))
}

# --- End to end: the review actually runs on the elided prompt ---

@test "end to end: huge one-line file does not stop the review; Claude gets a bounded prompt" {
  local diff_file="${MOCK_DIR}/pr.diff"
  _set_pr_diff data/climate.json 1245090

  mkdir -p "${MOCK_DIR}/home/.claude/hooks"
  cat >"${MOCK_DIR}/home/.claude/hooks/merge-lock.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "${MOCK_DIR}/home/.claude/hooks/merge-lock.sh"

  cat >"${MOCK_DIR}/gh" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "pr" && "\$2" == "view" ]]; then
  echo '{"number":24,"title":"data","reviewDecision":"","reviews":[],"comments":[],"state":"OPEN","statusCheckRollup":[]}'
  exit 0
fi
if [[ "\$1" == "pr" && "\$2" == "diff" ]]; then
  cat "${diff_file}"
  exit 0
fi
echo "[]"
exit 0
EOF
  chmod +x "${MOCK_DIR}/gh"

  cat >"${MOCK_DIR}/claude" <<EOF
#!/usr/bin/env bash
cat >"${MOCK_DIR}/prompt.txt"
echo "VERDICT: SAFE_TO_MERGE"
EOF
  chmod +x "${MOCK_DIR}/claude"

  run env HOME="${MOCK_DIR}/home" PATH="${MOCK_DIR}:${PATH}" \
    CLAUDE_CLI="${MOCK_DIR}/claude" \
    bash "${SCRIPT}" pr merge 24 --squash --delete-branch

  # Claude was invoked: the review ran instead of the hook dying.
  [[ -f "${MOCK_DIR}/prompt.txt" ]]
  local prompt_bytes
  prompt_bytes=$(wc -c <"${MOCK_DIR}/prompt.txt")
  # The pre-fix prompt was ~1.25 MB here. Bound it well below that.
  ((prompt_bytes < 300000))
  grep -qF '+const marker = "CODE_CHANGE_MARKER";' "${MOCK_DIR}/prompt.txt"
  grep -q "ELIDED: diff too large to include" "${MOCK_DIR}/prompt.txt"
  grep -q "File: data/climate.json" "${MOCK_DIR}/prompt.txt"
  # The prompt tells the model what an elided file means.
  grep -q "its content was NOT reviewed" "${MOCK_DIR}/prompt.txt"
}
