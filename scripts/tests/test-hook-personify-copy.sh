#!/usr/bin/env bash
# hook-block-personify.sh: staged copy is gated even where commit text is exempt (dev-env#206).

set -uo pipefail
unset CDPATH GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$(cd "${HERE}/.." && pwd)/hook-block-personify.sh"
[[ -x "${HOOK}" ]] || {
  echo "cannot find hook at ${HOOK}" >&2
  exit 1
}
TMP="$(mktemp -d)"
TMP="$(cd "${TMP}" && pwd -P)"
trap 'rm -rf "${TMP}"' EXIT

export HOME="${TMP}/home"
mkdir -p "${HOME}"
export CLAUDE_CONFIG_DIR="${HOME}/.claude"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_CEILING_DIRECTORIES="${TMP}"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com
export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
export XDG_CONFIG_HOME="${TMP}/xdg"
mkdir -p "${XDG_CONFIG_HOME}"
export GH_WRAPPER_LIB="${TMP}/no-wrapper.sh"
export GATE_REVIEW_DIR="${TMP}/gate"
GATE_GH="${HERE}/fixtures/gh-fork-stub.sh"
export GATE_GH
APPROVED="${GATE_REVIEW_DIR}/approved/k1"
mkdir -p "${GATE_REVIEW_DIR}/pending" "${APPROVED}"
# Commit text is exempt here (as for private kebab-tax-netlify), so only the copy check can block.
export GATE_RULES_FILE="${TMP}/rules.conf"
printf 'owner=nightowlstudiollc exempt\n* exempt\n' >"${GATE_RULES_FILE}"
export COPY_PATHS_FILE="${TMP}/copy-paths.conf"
cat >"${COPY_PATHS_FILE}" <<'CONF'
nightowlstudiollc/kebab-tax-netlify include *.html
nightowlstudiollc/kebab-tax-netlify include emails/*.html
nightowlstudiollc/kebab-tax-netlify include release-notes.json
CONF
mkdir -p "${CLAUDE_CONFIG_DIR}/plugins" "${TMP}/personify/scripts"
printf 'import sys\nsys.exit(0)\n' >"${TMP}/personify/scripts/length_check.py"
jq -n --arg p "${TMP}/personify" '{plugins:{"personify@personify":[{installPath:$p}]}}' \
  >"${CLAUDE_CONFIG_DIR}/plugins/installed_plugins.json"

pass=0
fail=0
_ok() {
  echo "  PASS  $1"
  pass=$((pass + 1))
}
_no() {
  echo "  FAIL  $1"
  fail=$((fail + 1))
}

# _run <cwd> <command>: pipe hook JSON in; set rc, err and extract.
_run() {
  local json
  json="$(jq -n --arg c "$2" --arg d "$1" '{tool_input:{command:$c},cwd:$d}')"
  err="$(printf '%s' "${json}" | "${HOOK}" 2>&1 >/dev/null)"
  rc=$?
  extract="$(printf '%s\n' "${err}" | sed -n 's/^  extract: //p')"
}
# _case <label> <want-rc> <want-substring> <cwd> <command>
_case() {
  local label="$1" wrc="$2" wsub="$3"
  _run "$4" "$5"
  if ((rc == wrc)) && [[ "${err}" == *"${wsub}"* ]]; then
    _ok "${label}"
  else
    _no "${label} (rc=${rc}): ${err}"
  fi
}
_contains() { # <label> <haystack> <needle> [absent]
  local found=0
  [[ "$2" != *"$3"* ]] || found=1
  if [[ "${4:-}" == absent ]]; then
    if ((found == 0)); then _ok "$1"; else _no "$1: found [$3] in [$2]"; fi
  elif ((found == 1)); then
    _ok "$1"
  else
    _no "$1: no [$3] in [$2]"
  fi
}
SITE="${TMP}/kebab-tax-netlify"
mkdir -p "${SITE}/emails"
git -C "${SITE}" init -q
git -C "${SITE}" remote add origin git@github.com:nightowlstudiollc/kebab-tax-netlify.git
cat >"${SITE}/index.html" <<'HTML'
<html><head><title>Kebab</title><style>h1 { color: red; }</style></head>
<body><h1>Track every donation</h1>
<p>Kebab keeps your receipts in one place.</p>
<p>Export a tax report in one tap.</p></body></html>
HTML
printf '# readme\n' >"${SITE}/README.md"
git -C "${SITE}" add index.html README.md
git -C "${SITE}" commit -q -m init

echo "--- not copy: unchanged behavior ---"
_case "nothing staged, exempt commit text: passes" 0 "" "${SITE}" "git commit -m x"
printf '# readme, edited\n' >"${SITE}/README.md"
git -C "${SITE}" add README.md
_case "staged non-copy file: not gated by the copy check" 0 "" "${SITE}" "git commit -m x"
git -C "${SITE}" reset -q

OTHER="${TMP}/other"
mkdir -p "${OTHER}"
git -C "${OTHER}" init -q
git -C "${OTHER}" remote add origin https://github.com/someone/else.git
printf '<p>Hello</p>\n' >"${OTHER}/index.html"
git -C "${OTHER}" add index.html
_case "repo with no conf entry: copy not gated" 0 "" "${OTHER}" "git commit -m x"

echo "--- public=*: READMEs in public repos (claude-config#735) ---"
cp "${COPY_PATHS_FILE}" "${TMP}/public.conf"
printf 'public=* include **/README*\n' >>"${TMP}/public.conf"
# _readme_repo <dir> <owner/name>: a repo with docs/readme.md staged.
_readme_repo() {
  mkdir -p "$1/docs"
  git -C "$1" init -q
  git -C "$1" remote add origin "git@github.com:$2.git"
  printf '# Hello\n\nA public readme.\n' >"$1/docs/readme.md"
  git -C "$1" add docs/readme.md
}
_readme_repo "${TMP}/pubrepo" someone/pubrepo
_readme_repo "${TMP}/privrepo" someone/privrepo
export GATE_TEST_PRIVATE="someone/privrepo"
COPY_PATHS_FILE="${TMP}/public.conf" _case "public repo, staged README: blocked" 2 \
  "public-facing copy that has not been approved" "${TMP}/pubrepo" "git commit -m x"
body="$(cat "${extract}" 2>/dev/null)"
_contains "  ... extract has the README text" "${body}" "A public readme."
COPY_PATHS_FILE="${TMP}/public.conf" _case "private repo, staged README: not gated" 0 "" \
  "${TMP}/privrepo" "git commit -m x"
unset GATE_TEST_PRIVATE

echo "--- public=* only: commit limits only when the call could commit a README ---"
printf 'public=* exclude **/vendor/**\n' >>"${TMP}/public.conf"
PO="${TMP}/pubonly"
mkdir -p "${PO}/src" "${PO}/docs" "${PO}/lib/vendor/x"
git -C "${PO}" init -q
git -C "${PO}" remote add origin git@github.com:someone/pubonly.git
printf 'a\n' >"${PO}/src/a.sh"
printf '# Old\n' >"${PO}/README.md"
printf '# Docs\n' >"${PO}/docs/README.md"
printf '# Lib\n' >"${PO}/lib/vendor/x/README.md"
git -C "${PO}" add src/a.sh README.md docs/README.md lib/vendor/x/README.md
git -C "${PO}" commit -q -m init
printf 'b\n' >"${PO}/src/a.sh"
printf 'new\n' >"${PO}/src/new.sh"
# _po <label> <want-rc> <want-substring> <command>: run the hook in PO with public.conf.
_po() { COPY_PATHS_FILE="${TMP}/public.conf" _case "$1" "$2" "$3" "${PO}" "$4"; }
_po "no README involved: git add x && git commit passes" 0 "" "git add src/a.sh && git commit -m x"
_po "no README involved: a new file through git add passes" 0 "" "git add src/new.sh src && git commit -m x"
_po "no README involved: commit -a passes" 0 "" "git commit -a -m x"
_po "no README involved: commit -am passes" 0 "" "git commit -am x"
_po "no README involved: commit pathspec passes" 0 "" "git commit -m x src/a.sh"
_po "no README involved: git -C add && git -C commit passes" 0 "" \
  "git -C ${PO} add src/a.sh && git -C ${PO} commit -m x"
_po "no README involved: cd, add, commit, pipe into tail passes" 0 "" \
  "cd ${PO} && git add -A && git commit -m x 2>&1 | tail -3"
_po "a vendored README is not copy: git add . passes" 0 "" "git add . && git commit -m x"
printf '# Vendored, edited\n' >"${PO}/lib/vendor/x/README.md"
_po "  ... nor with the vendored README edited" 0 "" "git add . && git commit -m x"
printf '# New\n' >"${PO}/README.md"
_po "README modified, git add README.md && git commit: blocked" 2 "could commit public-facing copy (README.md)" \
  "git add README.md && git commit -m x"
_po "README modified, git add . && git commit: blocked" 2 "README.md" "git add . && git commit -m x"
_po "README modified, git add -u && git commit: blocked" 2 "README.md" "git add -u && git commit -m x"
_po "README modified, commit -a: blocked" 2 "README.md" "git commit -a -m x"
_po "README modified, commit pathspec .: blocked" 2 "README.md" "git commit -m x ."
_po "README modified, other file added: passes" 0 "" "git add src/a.sh && git commit -m x"
git -C "${PO}" checkout -q -- README.md
printf '# Docs, edited\n' >"${PO}/docs/README.md"
_po "nested README under a named directory: blocked" 2 "docs/README.md" "git add docs && git commit -m x"
git -C "${PO}" checkout -q -- docs/README.md
_po "undecidable: a file write in the call gets the strict limits" 2 "another git command" \
  "echo x > src/a.sh && git add src/a.sh && git commit -m x"
_po "undecidable: a variable pathspec gets the strict limits" 2 "another git command" \
  "git add \"\$F\" && git commit -m x"
_po "undecidable: git pull in the call gets the strict limits" 2 "another git command" \
  "git pull && git commit -m x"
_po "undecidable: piping into tee gets the strict limits" 2 "another git command" \
  "git add src/a.sh && git commit -m x | tee out"
_po "undecidable: a background job gets the strict limits" 2 "(-a)" "touch x & git commit -a -m x"
_po "undecidable: an assignment before git gets the strict limits" 2 "another git command" \
  "GIT_INDEX_FILE=/tmp/i git add src/a.sh && git commit -m x"
_po "commit -p is never relaxed" 2 "(-p)" "git commit -p -m x"
printf '# New\n' >"${PO}/README.md"
_po "a second commit after the first gets the strict limits" 2 "another git command" \
  "git add src/a.sh && git commit -m a && git add README.md && git commit -m b"
_po "git commit then commit -a gets the strict limits" 2 "another git command" \
  "git commit -m x && git commit -a -m y"
_po "git add hidden in bash -c after the commit gets the strict limits" 2 "another git command" \
  "git commit -m x; bash -c 'git add README.md'"
_po "a command substitution in the message gets the strict limits" 2 "another git command" \
  "git commit -m \"\$(git add README.md)\""
_po "brace expansion in a pathspec gets the strict limits" 2 "another git command" \
  "git add README.{md,txt} && git commit -m x"
_po "git push after the commit stays relaxed" 0 "" "git add src/a.sh && git commit -m x && git push"
_po "a quoted message holding a separator gets the strict limits" 2 "another git command" \
  "git add src/a.sh && git commit -m \"fix: a; b\""
_po "a quoted message without a separator stays relaxed" 0 "" "git add src/a.sh && git commit -m \"fix: a b\""
_po "cd to a non-literal target gets denied or strict" 2 "" "cd \"\$X\" && git add README.md && git commit -m x"
COPY_PATHS_FILE="${TMP}/public.conf" _case "cd into the repo from elsewhere: README still found" 2 \
  "could commit public-facing copy (README.md)" "${TMP}" "cd ${PO} && git add . && git commit -m x"
COPY_PATHS_FILE="${TMP}/public.conf" _case "git -C from elsewhere: README still found" 2 \
  "could commit public-facing copy (README.md)" "${TMP}" "git -C ${PO} add . && git -C ${PO} commit -m x"
git -C "${PO}" checkout -q -- README.md
printf '# Staged\n' >"${PO}/README.md"
git -C "${PO}" add README.md
_po "README staged, plain commit: extract and approval as before" 2 "public-facing copy that has not been approved" \
  "git commit -m x"
_contains "  ... with an extract" "${err}" "extract: ${GATE_REVIEW_DIR}/copy/"
git -C "${PO}" reset -q
git -C "${PO}" checkout -q -- README.md
COPY_PATHS_FILE="${TMP}/public.conf" _case "own lines plus public=*: strict limits as before" 2 \
  "another git command" "${SITE}" "git add README.md && git commit -m x"

echo "--- copy changed in a repo whose commit text is exempt ---"
sed -i.bak -e 's#Export a tax report in one tap.#Export a tax report in two taps.#' "${SITE}/index.html"
git -C "${SITE}" add index.html
_case "staged copy change: blocked" 2 "public-facing copy that has not been approved" "${SITE}" \
  "git commit -m 'fix: wording'"
_contains "  ... names the extract" "${err}" "extract: ${GATE_REVIEW_DIR}/copy/"
_contains "  ... and the stage --kind copy step" "${err}" "stage --kind copy copy-"
EX1="${extract}"
_contains "  ... and no Pangram check step" "${err}" "pangram_check" absent
body="$(cat "${EX1}" 2>/dev/null)"
_contains "  ... extract has the changed text" "${body}" "Export a tax report in two taps."
_contains "  ... and not the unchanged text" "${body}" "Kebab keeps your receipts" absent
_contains "  ... and no CSS" "${body}" "color: red" absent
_case "git -C from another cwd: blocked too" 2 "public-facing copy" "${TMP}" \
  "git -C ${SITE} commit -m x"

# Approval: the approved bytes alone. No Pangram record is needed (2026-10-22).
cp "${EX1}" "${APPROVED}/copy-1"
_case "approved, no Pangram record: passes" 0 "" "${SITE}" "git commit -m x"
rm -f "${APPROVED}/copy-1"
_case "no approval: blocked" 2 "rule copy (review): no visual approval matches" "${SITE}" "git commit -m x"
cp "${EX1}" "${APPROVED}/copy-1"
_run "${SITE}" "git commit -m x"
if [[ "${rc}" == 0 && -z "${extract}" ]]; then
  _ok "same staged text again: same bytes, passes"
else
  _no "same staged text again (rc=${rc}): ${err}"
fi

sed -i.bak -e 's#in two taps#in three taps#' "${SITE}/index.html"
git -C "${SITE}" add index.html
_case "copy edited after approval: blocked again" 2 "public-facing copy" "${SITE}" "git commit -m x"
git -C "${SITE}" checkout -q -- index.html 2>/dev/null
git -C "${SITE}" reset -q --hard

echo "--- new file: whole text ---"
cat >"${SITE}/emails/welcome.html" <<'HTML'
<html><body><p>Welcome to the beta.</p><p>Reply to this email with feedback.</p></body></html>
HTML
git -C "${SITE}" add emails/welcome.html
_case "new copy file: blocked" 2 "public-facing copy" "${SITE}" "git commit -m x"
body="$(cat "${extract}" 2>/dev/null)"
_contains "  ... shows the whole text" "${body}" $'>> emails/welcome.html (new file, whole text)\nWelcome to the beta.\nReply to this email with feedback.'
git -C "${SITE}" reset -q

echo "--- markup-only change ---"
sed -i.bak -e 's#<h1>#<h1 class="hero">#' "${SITE}/index.html"
git -C "${SITE}" add index.html
_case "class change only: empty extract passes" 0 "" "${SITE}" "git commit -m x"

echo "--- the index must be what commits ---"
git -C "${SITE}" reset -q --hard
sed -i.bak -e 's#one place#a single place#' "${SITE}/index.html"
_case "git add && git commit in one call: blocked" 2 "another git command" "${SITE}" \
  "git add index.html && git commit -m x"
_case "git commit -am: blocked" 2 "(-a)" "${SITE}" "git commit -am x"
_case "git commit --all: blocked" 2 "(--all)" "${SITE}" "git commit --all -m x"
_case "git commit --al (abbreviated --all): blocked" 2 "(--al)" "${SITE}" "git commit --al -m x"
_case "git commit --onl (abbreviated --only): blocked" 2 "(--onl)" "${SITE}" "git commit --onl -m x"
_case "git commit with a path: blocked" 2 "path 'index.html'" "${SITE}" "git commit -m x index.html"
_case "git commit -- path: blocked" 2 "pathspec after --" "${SITE}" "git commit -m x -- index.html"
_case "-F value and 2>&1 are not paths" 0 "" "${SITE}" "git commit -F /dev/null 2>&1"
_case "heredoc -F - is not a path" 0 "" "${SITE}" "git commit -F - <<'EOF'
fix: a message
EOF"
git -C "${SITE}" reset -q --hard

echo "--- fail closed ---"
printf '{"releases": [\n' >"${SITE}/release-notes.json"
git -C "${SITE}" add release-notes.json
_case "extraction error (bad JSON): blocked" 2 "cannot extract" "${SITE}" "git commit -m x"
git -C "${SITE}" reset -q
COPY_PATHS_FILE="${TMP}/missing.conf" _case "conf missing: blocked, even in a repo with no entry" 2 \
  "copy paths file not found" "${OTHER}" "git commit -m x"
printf 'nightowlstudiollc/kebab-tax-netlify include\n' >"${TMP}/bad.conf"
COPY_PATHS_FILE="${TMP}/bad.conf" _case "conf malformed: blocked" 2 "expected '<owner/name|public=*>" "${OTHER}" \
  "git commit -m x"
mkdir -p "${GATE_REVIEW_DIR}"
printf '2999-12-31\n' >"${GATE_REVIEW_DIR}/SUSPENDED"
COPY_PATHS_FILE="${TMP}/missing.conf" _case "SUSPENDED is the escape hatch" 0 "" "${OTHER}" "git commit -m x"
rm -f "${GATE_REVIEW_DIR}/SUSPENDED"

echo "--- the Pangram copy guard is gone: prose that names it passes ---"
# The guard blocked heredocs whose prose named pangram_check.py --kind copy; gate v3 drops Pangram.
_case "heredoc prose naming --kind copy: untouched" 0 "" "${TMP}" "cat > ${TMP}/n.md <<EOF
run pangram_check.py --kind copy on it
EOF"
_case "sort -k2 after a variable: untouched" 0 "" "${TMP}" "sort -k2 \$F"

echo ""
echo "${pass} passed, ${fail} failed"
((fail == 0))
