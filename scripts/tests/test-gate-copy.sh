#!/usr/bin/env bash
# gate-copy.py (conf, globs, extraction) and gate-review.sh's copy kind. Hook side: test-hook-personify-copy.sh.

set -uo pipefail
unset CDPATH GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$(cd "${HERE}/.." && pwd)"
COPY="${SCRIPTS}/gate-copy.py"
GATE="${SCRIPTS}/gate-review.sh"
REAL_CONF="$(cd "${SCRIPTS}/.." && pwd)/copy-paths.conf"
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
mkdir -p "${XDG_CONFIG_HOME}/personify/checks"
export GH_WRAPPER_LIB="${TMP}/no-wrapper.sh"
export GATE_REVIEW_DIR="${TMP}/gate"
GATE_GH="${HERE}/fixtures/gh-fork-stub.sh"
export GATE_GH
export GATE_RULES_FILE="${TMP}/rules.conf"
printf 'owner=nightowlstudiollc exempt\n* exempt\n' >"${GATE_RULES_FILE}"
# A length_check.py that FAILS everything: the copy kind must never call it.
mkdir -p "${CLAUDE_CONFIG_DIR}/plugins" "${TMP}/personify/scripts"
: >"${TMP}/personify/scripts/pangram_check.py"
printf 'import sys\nprint("over by 999 words")\nsys.exit(1)\n' >"${TMP}/personify/scripts/length_check.py"
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
# _eq <label> <want> <got>
_eq() {
  if [[ "$2" == "$3" ]]; then _ok "$1"; else _no "$1: want [$2] got [$3]"; fi
}
# _eqo <label> <want> <command...>: the command's output.
_eqo() {
  local got
  got="$("${@:3}" 2>&1)"
  _eq "$1" "$2" "${got}"
}
# _eqr <label> <want-rc> <command...>: the command's exit code.
_eqr() {
  local rc=0
  "${@:3}" >/dev/null 2>&1 || rc=$?
  _eq "$1" "$2" "${rc}"
}
# _first <command...>: the first tab-separated field of the command's output.
_first() {
  local out
  out="$("$@")"
  printf '%s\n' "${out%%$'\t'*}"
}
_has() {
  if [[ "$3" == *"$2"* ]]; then _ok "$1"; else _no "$1: [$2] not in [$3]"; fi
}
_hasnt() {
  if [[ "$3" != *"$2"* ]]; then _ok "$1"; else _no "$1: [$2] unexpectedly in [$3]"; fi
}

CONF="${TMP}/copy-paths.conf"
export COPY_PATHS_FILE="${CONF}"
cat >"${CONF}" <<'CONF'
# comment
o/site include *.html
o/site include emails/*.html
o/site include data/**/*.txt
o/site exclude data/**/*_url.txt
O/Blog include posts/**
O/Blog exclude posts/drafts/**
CONF

echo "--- conf parsing and glob semantics ---"
_match() { python3 "${COPY}" match --repo "$1" "${@:2}" 2>&1; }
_eqo "*.html is root-only" "index.html" _match o/site index.html sub/x.html
_eqo "emails/*.html matches one level" "emails/a.html" _match o/site emails/a.html emails/x/a.html
_eqo "**/ matches zero or more dirs" $'data/a.txt\ndata/en/b.txt' _match o/site data/a.txt data/en/b.txt
_eqo "exclude wins over include" "" _match o/site data/en/privacy_url.txt
_eqo "repo name is case-insensitive" "posts/a.md" _match o/blog posts/a.md posts/drafts/b.md
_eqo "unknown repo has no copy paths" "" _match o/other index.html
_eqo "dot is literal" "" _match o/site indexXhtml

_conf_rc() {
  printf '%s\n' "$1" >"${TMP}/bad.conf"
  COPY_PATHS_FILE="${TMP}/bad.conf" python3 "${COPY}" match --repo o/site x
}
_match_with() { COPY_PATHS_FILE="$1" python3 "${COPY}" match --repo o/site x; }
_eqr "two fields: malformed (4)" 4 _conf_rc 'o/site include'
_eqr "unknown kind: malformed (4)" 4 _conf_rc 'o/site maybe *.html'
_eqr "repo not owner/name: malformed (4)" 4 _conf_rc 'site include *.html'
_eqr "absolute glob: malformed (4)" 4 _conf_rc 'o/site include /etc/*'
_eqr "empty conf: fails closed (4)" 4 _conf_rc ''
_eqr "comment-only conf: fails closed (4)" 4 _conf_rc '# nothing here'
_eqr "missing conf (4)" 4 _match_with "${TMP}/nope.conf"

echo "--- the real copy-paths.conf ---"
_real() { COPY_PATHS_FILE="${REAL_CONF}" python3 "${COPY}" match --repo "$1" "${@:2}" 2>&1; }
_eqr "real conf parses" 0 _match_with "${REAL_CONF}"
_eqo "kebab.tax: pages, emails, release notes; not README or nested html" \
  $'index.html\nemails/beta-invitation.html\nrelease-notes.json\nAPP_STORE_COPY.txt' \
  _real nightowlstudiollc/kebab-tax-netlify index.html emails/beta-invitation.html release-notes.json \
  APP_STORE_COPY.txt README.md node_modules/x/index.html netlify/functions/a.mjs
_eqo "kebab-tax: fastlane text, not *_url.txt, not app source (phase 2)" \
  $'mobile/fastlane/metadata/en-US/description.txt\nmobile/fastlane/metadata/android/en-US/changelogs/default.txt' \
  _real nightowlstudiollc/kebab-tax mobile/fastlane/metadata/en-US/description.txt \
  mobile/fastlane/metadata/android/en-US/changelogs/default.txt mobile/fastlane/metadata/en-US/support_url.txt \
  mobile/src/screens/Home.tsx mobile/src/config/easterEggMessages.ts
_eqo "amelia-boone: posts, not pagefind output" "src/data/blog/a.md" \
  _real nightowlstudiollc/amelia-boone src/data/blog/a.md public/pagefind/x.html README.md

echo "--- extraction ---"
REPO="${TMP}/site"
mkdir -p "${REPO}"
git -C "${REPO}" init -q
git -C "${REPO}" remote add origin git@github.com:o/site.git
OUT="${TMP}/out"
_extract() { python3 "${COPY}" extract --dir "${REPO}" --out-dir "${OUT}"; }
# The extract's text, or the extractor's exit code as "rc=N" (with any path).
_text() {
  local p rc=0
  p="$(_extract)" || rc=$?
  if ((rc != 0)) || [[ -z "${p}" ]]; then
    printf 'rc=%s path=%s\n' "${rc}" "${p}"
    return 0
  fi
  cat "${p}"
}
_sha() {
  local o
  o="$(sha256sum "$1")"
  printf '%s\n' "${o%% *}"
}
_eqo "nothing staged: repo has copy paths (0), no extract" "rc=0 path=" _text

cat >"${REPO}/index.html" <<'HTML'
<html><head><title>Kebab</title>
<meta name="description" content="Track your donations.">
<style>.x { color: red; }</style><script>var a = "not copy";</script></head>
<body><h1>Welcome</h1>
<p>First paragraph
   wraps here.</p>
<p>Second <b>bold</b> paragraph.</p>
<img src="a.png" alt="A kebab"></body></html>
HTML
git -C "${REPO}" add index.html
p="$(_extract)"
got="$(_text)"
_eq "new HTML file: whole text, no CSS or script" ">> index.html (new file, whole text)
Kebab
Track your donations.
Welcome
First paragraph wraps here.
Second bold paragraph.
A kebab" "${got}"
sha="$(_sha "${p}")"
_eq "extract is named by its sha256" "${sha}.txt" "${p##*/}"
_eqo "same staged text, same bytes, same path" "${p}" _extract
git -C "${REPO}" commit -q -m init

sed -i.bak -e 's#Second <b>bold</b> paragraph.#Second paragraph, reworded.#' "${REPO}/index.html"
git -C "${REPO}" add index.html
got="$(_text)"
_eq "changed HTML: only the changed text" ">> index.html (added or changed text)
Second paragraph, reworded." "${got}"
git -C "${REPO}" commit -q -m two

# Rewrap and a class change only.
sed -i.bak -e 's#<p>First paragraph#<p class="lead">First#; s#   wraps here.#paragraph wraps here.#' "${REPO}/index.html"
git -C "${REPO}" add index.html
_eqo "markup-only and rewrap change: no extract" "rc=0 path=" _text
git -C "${REPO}" commit -q -m three

mkdir -p "${REPO}/data/en"
printf '{"version": "1.2.0", "date": "2026-10-15", "notes": [{"text": "Faster imports"}]}\n' >"${REPO}/data/en/notes.txt"
cp "${REPO}/data/en/notes.txt" "${REPO}/release.json"
printf 'o/site include release.json\n' >>"${CONF}"
git -C "${REPO}" add release.json
got="$(_text)"
_eq "JSON: string values with letters only" ">> release.json (new file, whole text)
Faster imports" "${got}"
printf '{"notes": [\n' >"${REPO}/release.json"
git -C "${REPO}" add release.json
_extract >/dev/null 2>&1
_eq "malformed JSON: extraction error (5)" 5 "$?"
git -C "${REPO}" commit -q -m bad-json
cp "${REPO}/data/en/notes.txt" "${REPO}/release.json"
git -C "${REPO}" add release.json
got="$(_text)"
_eq "malformed JSON in HEAD: the fix is not blocked, whole text shown" ">> release.json (old version unreadable, whole text)
Faster imports" "${got}"
git -C "${REPO}" rm -q --cached release.json
git -C "${REPO}" commit -q -m drop-json

printf '%s\n' '---' 'title: "Hello there"' 'pubDatetime: 2026-01-01' '---' '' '# A heading' '' \
  'Some *emphasis* and a [link](https://x.y) and' 'a wrapped line.' '' '```' 'code() {}' '```' '' \
  '- a list item' '' 'See <img src="x.png" alt="the receipt screen"> here.' '' \
  'Fees run < 5 dollars and > 1 dollar.' >"${REPO}/post.md"
printf 'o/site include post.md\n' >>"${CONF}"
git -C "${REPO}" add post.md
got="$(_text)"
_eq "Markdown: frontmatter title, text only, no code" ">> post.md (new file, whole text)
Hello there
A heading
Some emphasis and a link and a wrapped line.
a list item
See the receipt screen here.
Fees run < 5 dollars and > 1 dollar." "${got}"
git -C "${REPO}" rm -q --cached post.md

printf '%s\n' '---' "import Base from '../x.astro';" '---' '<Base title="Now">' '<h1>Now</h1>' \
  '<p>Reading {books.length} books.</p>' '</Base>' >"${REPO}/now.astro"
printf 'o/site include now.astro\n' >>"${CONF}"
git -C "${REPO}" add now.astro
got="$(_text)"
# The layout's title prop is copy (it becomes the page <title>), so it shows.
_eq "Astro: frontmatter and {expressions} dropped" ">> now.astro (new file, whole text)
Now
Now
Reading books." "${got}"
git -C "${REPO}" rm -q --cached now.astro

printf '%s\n' "import Chart from './c.astro';" 'export const x = 1;' '' 'Export your data in one tap.' \
  'import the list, then review it.' 'import receipts from your bank, then review them.' \
  "export let's publish your data." 'export default settings work for most people.' \
  'export functions (and charts) to PDF.' "export { a } from './a.js';" \
  'export your data from "Settings"' "import * as m from 'm';" 'import "./s.css";' >"${REPO}/post.mdx"
printf 'o/site include post.mdx\n' >>"${CONF}"
git -C "${REPO}" add post.mdx
got="$(_text)"
_eq "MDX: module imports dropped, other import/export lines kept" ">> post.mdx (new file, whole text)
export const x = 1;
Export your data in one tap. import the list, then review it. import receipts from your bank, then review them. export let's publish your data. export default settings work for most people. export functions (and charts) to PDF.
export your data from \"Settings\"" "${got}"
git -C "${REPO}" rm -q --cached post.mdx

UNKNOWN="${TMP}/unknown"
mkdir -p "${UNKNOWN}"
git -C "${UNKNOWN}" init -q
git -C "${UNKNOWN}" remote add origin https://github.com/o/other.git
printf '<p>x</p>\n' >"${UNKNOWN}/index.html"
git -C "${UNKNOWN}" add index.html
python3 "${COPY}" extract --dir "${UNKNOWN}" --out-dir "${OUT}" >/dev/null 2>&1
_eq "repo not in the conf: not copy (3)" 3 "$?"
git -C "${UNKNOWN}" remote set-url origin https://gitlab.com/o/site.git
python3 "${COPY}" extract --dir "${UNKNOWN}" --out-dir "${OUT}" >/dev/null 2>&1
_eq "non-github origin: not copy (3)" 3 "$?"
COPY_PATHS_FILE="${TMP}/nope.conf" python3 "${COPY}" extract --dir "${UNKNOWN}" --out-dir "${OUT}" >/dev/null 2>&1
_eq "missing conf fails closed even for an unknown repo (4)" 4 "$?"
: >"${TMP}/empty.conf"
COPY_PATHS_FILE="${TMP}/empty.conf" python3 "${COPY}" extract --dir "${UNKNOWN}" --out-dir "${OUT}" >/dev/null 2>&1
_eq "empty conf: extract fails closed (4)" 4 "$?"
# A git error reading origin (here: a corrupt config) is an error (5), not "not copy".
printf '[remote "origin"\n' >>"${UNKNOWN}/.git/config"
python3 "${COPY}" extract --dir "${UNKNOWN}" --out-dir "${OUT}" >/dev/null 2>&1
_eq "git error reading origin: fails closed (5)" 5 "$?"

echo "--- gate-review.sh copy kind ---"
printf 'Some copy text.\n' >"${TMP}/extract.txt"
_eqo "route --kind copy ignores gate-rules (exempt repo)" "pangram" \
  _first "${GATE}" route --kind copy --dir "${REPO}"
_eqo "route --kind copy with no destination is still pangram" "pangram" \
  _first "${GATE}" route --kind copy
_eqo "route --kind commit in the same repo is exempt (control)" $'gate-route: author unresolved\nexempt' \
  _first "${GATE}" route --kind commit --dir "${REPO}"
err="$("${GATE}" check "${TMP}/extract.txt" --kind copy --dir "${REPO}" 2>&1)"
_eq "check --kind copy in an exempt repo: not approved (1)" 1 "$?"
_has "  ... says no Pangram check ran" "no Pangram check ran" "${err}"
err="$(cd "${REPO}" && "${GATE}" stage --kind copy c1 "${TMP}/extract.txt" 2>&1)"
_eq "stage --kind copy without a record: refused" 1 "$?"
_has "  ... asks for the Pangram check" "no Pangram check record" "${err}"
sha="$(_sha "${TMP}/extract.txt")"
printf '{"status":"PASS","verdict":"Human","fraction_ai":0.0,"word_count":3}\n' \
  >"${XDG_CONFIG_HOME}/personify/checks/${sha}.json"
err="$(cd "${REPO}" && "${GATE}" stage --kind copy c1 "${TMP}/extract.txt" 2>&1)"
_eq "stage --kind copy with a record: staged, no length check" 0 "$?"
_hasnt "  ... never measured" "over by" "${err}"
mkdir -p "${GATE_REVIEW_DIR}/approved/k1"
cp "${TMP}/extract.txt" "${GATE_REVIEW_DIR}/approved/k1/c1"
"${GATE}" check "${TMP}/extract.txt" --kind copy --dir "${REPO}" >/dev/null 2>&1
_eq "approved bytes plus a record: check passes" 0 "$?"

echo ""
echo "${pass} passed, ${fail} failed"
((fail == 0))
