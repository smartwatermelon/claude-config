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
CHECKS="${XDG_CONFIG_HOME}/personify/checks"
mkdir -p "${CHECKS}"
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
: >"${TMP}/personify/scripts/pangram_check.py"
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
_sha() {
  local o
  o="$(sha256sum "$1")"
  printf '%s\n' "${o%% *}"
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

echo "--- copy changed in a repo whose commit text is exempt ---"
sed -i.bak -e 's#Export a tax report in one tap.#Export a tax report in two taps.#' "${SITE}/index.html"
git -C "${SITE}" add index.html
_case "staged copy change: blocked" 2 "public-facing copy that has not been approved" "${SITE}" \
  "git commit -m 'fix: wording'"
_contains "  ... names the extract" "${err}" "extract: ${GATE_REVIEW_DIR}/copy/"
_contains "  ... and the stage --kind copy step" "${err}" "stage --kind copy copy-"
EX1="${extract}"
_contains "  ... and the check hint names the copy kind" "${err}" "pangram_check.py --kind copy < ${EX1}"
body="$(cat "${EX1}" 2>/dev/null)"
_contains "  ... extract has the changed text" "${body}" "Export a tax report in two taps."
_contains "  ... and not the unchanged text" "${body}" "Kebab keeps your receipts" absent
_contains "  ... and no CSS" "${body}" "color: red" absent
_case "git -C from another cwd: blocked too" 2 "public-facing copy" "${TMP}" \
  "git -C ${SITE} commit -m x"

# Approval: the record (proof Pangram ran) and the approved bytes, both needed.
REC="${CHECKS}/$(_sha "${EX1}").json"
cp "${EX1}" "${APPROVED}/copy-1"
_case "approved but no Pangram record: blocked" 2 "no Pangram check ran" "${SITE}" "git commit -m x"
printf '{"status":"SKIPPED","word_count":12}\n' >"${REC}"
_case "approved, with record: passes" 0 "" "${SITE}" "git commit -m x"
rm -f "${APPROVED}/copy-1"
_case "record but no approval: blocked" 2 "no visual approval matches" "${SITE}" "git commit -m x"
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
COPY_PATHS_FILE="${TMP}/bad.conf" _case "conf malformed: blocked" 2 "expected '<owner/name>" "${OTHER}" \
  "git commit -m x"
mkdir -p "${GATE_REVIEW_DIR}"
printf '2999-12-31\n' >"${GATE_REVIEW_DIR}/SUSPENDED"
COPY_PATHS_FILE="${TMP}/missing.conf" _case "SUSPENDED is the escape hatch" 0 "" "${OTHER}" "git commit -m x"
rm -f "${GATE_REVIEW_DIR}/SUSPENDED"

echo "--- route guard: pangram_check.py --kind copy reads only a copy extract ---"
# --kind copy always routes to Pangram, so it must not run on arbitrary text.
PC="python3 ${TMP}/personify/scripts/pangram_check.py"
COPYDIR="${GATE_REVIEW_DIR}/copy"
mkdir -p "${COPYDIR}"
GOOD="${COPYDIR}/$(printf 'guard' | sha256sum | cut -d' ' -f1).txt"
printf 'a copy extract\n' >"${GOOD}"
OUTSIDE="${TMP}/x.md"
printf 'some other text\n' >"${OUTSIDE}"
ln -s "${OUTSIDE}" "${COPYDIR}/link.txt"
_case "--kind copy < /tmp/x.md: blocked" 2 "not a copy extract" "${TMP}" "${PC} --kind copy < /tmp/x.md"
_case "--kind copy from a file outside the copy dir: blocked" 2 "not a copy extract" "${TMP}" \
  "${PC} --kind copy < ${OUTSIDE}"
_case "--kind copy from a copy extract: allowed" 0 "" "${TMP}" "${PC} --kind copy < ${GOOD}"
_case "--kind=copy from a copy extract: allowed" 0 "" "${TMP}" "${PC} --kind=copy < ${GOOD}"
_case "copy extract with --dir too: allowed" 0 "" "${TMP}" "${PC} --kind copy --dir ${SITE} < ${GOOD}"
_case "bare pangram_check.py path, no python3: allowed" 0 "" "${TMP}" \
  "${TMP}/personify/scripts/pangram_check.py --kind copy < ${GOOD}"
_case "--kind=copy outside: blocked" 2 "not a copy extract" "${TMP}" "${PC} --kind=copy < ${OUTSIDE}"
_case "--ki copy (argparse prefix) outside: blocked" 2 "not a copy extract" "${TMP}" "${PC} --ki copy < ${OUTSIDE}"
_case "quoted copy: blocked" 2 "shell syntax" "${TMP}" "${PC} --kind 'copy' < ${GOOD}"
_case "variable kind: blocked" 2 "shell syntax" "${TMP}" "${PC} --kind \"\${K}\" < ${OUTSIDE}"
_case "piped into --kind copy: blocked" 2 "shell syntax" "${TMP}" "cat ${OUTSIDE} | ${PC} --kind copy"
_case "heredoc into --kind copy: blocked" 2 "more than one line" "${TMP}" "${PC} --kind copy <<EOF
any text at all
EOF"
_case "no stdin redirect: blocked" 2 "one < redirect" "${TMP}" "${PC} --kind copy"
_case "here-string into --kind copy: blocked" 2 "one < redirect" "${TMP}" "${PC} --kind copy <<< text"
_case "relative stdin path: blocked" 2 "not absolute" "${TMP}" "${PC} --kind copy < x.md"
_case ".. out of the copy dir: blocked" 2 ". or .." "${TMP}" "${PC} --kind copy < ${COPYDIR}/../../x.md"
_case "symlink in the copy dir: blocked" 2 "not a regular file" "${TMP}" "${PC} --kind copy < ${COPYDIR}/link.txt"
_case "a second command after it: blocked" 2 "shell syntax" "${TMP}" "${PC} --kind copy < ${GOOD} && echo hi"
_case "an extra argument: blocked" 2 "unexpected argument" "${TMP}" "${PC} --kind copy --title x < ${GOOD}"
_case "--kind commit with --dir: not copy, untouched" 0 "" "${TMP}" "${PC} --kind commit --dir ${SITE} < ${OUTSIDE}"
_case "no --kind at all: untouched" 0 "" "${TMP}" "${PC} --repo acme/x < ${OUTSIDE}"
_case "--check-key: untouched" 0 "" "${TMP}" "${PC} --check-key"
_case "no pangram_check.py: untouched" 0 "" "${TMP}" "echo --kind copy < ${OUTSIDE}"
# Quoting hides the flag from a plain text match; the guard reads unquoted words.
_case "\"--kind\" copy outside: blocked" 2 "shell syntax" "${TMP}" "${PC} \"--kind\" copy < ${OUTSIDE}"
_case "\\--kind copy outside: blocked" 2 "shell syntax" "${TMP}" "${PC} \\--kind copy < ${OUTSIDE}"
_case "--k\\ind copy outside: blocked" 2 "shell syntax" "${TMP}" "${PC} --k\\ind copy < ${OUTSIDE}"
_case "-kcopy outside: blocked" 2 "unexpected argument" "${TMP}" "${PC} -kcopy < ${OUTSIDE}"
_case "escaped script name, --kind copy outside: blocked" 2 "shell syntax" "${TMP}" \
  "python3 ${TMP}/personify/scripts/pangram_che\\ck.py --kind copy < ${OUTSIDE}"
_case "unbalanced quote: blocked" 2 "shell syntax" "${TMP}" "${PC} --kind copy < '${OUTSIDE}"
_case "globbed script name, --kind copy: blocked" 2 "shell syntax" "${TMP}" \
  "python3 ${TMP}/personify/scripts/pangram_che*.py --kind copy < ${OUTSIDE}"
_case "script name from a variable, --kind copy: blocked" 2 "shell syntax" "${TMP}" \
  "python3 \${P}/pangram_check.py --kind copy < ${OUTSIDE}"
_case "substituted script name, --kind copy: blocked" 2 "shell syntax" "${TMP}" \
  "python3 \$(ls ${TMP}/personify/scripts/pangram*) --kind copy < ${OUTSIDE}"
_case "grep for the name with a pipe: untouched" 0 "" "${TMP}" "grep -rn pangram_check scripts | head -5"
_case "quoted --dir, no copy: untouched" 0 "" "${TMP}" "${PC} --kind pr --dir \"${SITE}\" < ${OUTSIDE}"

echo ""
echo "${pass} passed, ${fail} failed"
((fail == 0))
