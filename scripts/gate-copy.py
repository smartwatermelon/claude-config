#!/usr/bin/env python3
"""Write the added or changed text of staged copy files (dev-env#206 copy gate).

extract --dir D --out-dir O: exit 0 (stdout: extract path, or empty), 3 not copy,
4 bad conf, 5 git or parse error. match --repo R PATH...: print the copy paths.
"""

import hashlib
import json
import os
import re
import subprocess
import sys
import time
from difflib import SequenceMatcher
from html.parser import HTMLParser

CONF_ENV = "COPY_PATHS_FILE"


def conf_path():
    """$COPY_PATHS_FILE, else ~/.claude/copy-paths.conf, else the repo copy
    beside this script (a git pull lands before install.sh --sync links it)."""
    env = os.environ.get(CONF_ENV)
    if env:
        return env
    deployed = os.path.join(os.path.expanduser("~"), ".claude", "copy-paths.conf")
    if os.path.lexists(deployed):
        return deployed
    here = os.path.dirname(os.path.realpath(__file__))
    return os.path.join(os.path.dirname(here), "copy-paths.conf")


class ConfError(Exception):
    pass


PUBLIC = "public=*"


def glob_to_regex(glob, nocase=False):
    """`**/` matches zero or more directories, `**` anything, `*` and `?`
    stay within one path component. Everything else is literal."""
    out = []
    i = 0
    while i < len(glob):
        if glob.startswith("**/", i):
            out.append("(?:.*/)?")
            i += 3
        elif glob.startswith("**", i):
            out.append(".*")
            i += 2
        elif glob[i] == "*":
            out.append("[^/]*")
            i += 1
        elif glob[i] == "?":
            out.append("[^/]")
            i += 1
        else:
            out.append(re.escape(glob[i]))
            i += 1
    return re.compile("^" + "".join(out) + "$", re.IGNORECASE if nocase else 0)


def load_conf(path):
    """Return ({repo: (includes, excludes)}, (public includes, public excludes)).
    `public=*` globs ignore case. Any problem raises ConfError, so a caller
    never gates on a truncated list."""
    try:
        with open(path, encoding="utf-8") as f:
            lines = f.read().splitlines()
    except (OSError, UnicodeDecodeError) as e:
        raise ConfError(
            f"copy paths file not found or unreadable: {path} ({e}); "
            "to deploy it, run install.sh --sync in the claude-config repo"
        ) from e
    rules = {}
    public = ([], [])
    for n, line in enumerate(lines, 1):
        fields = line.split()
        if not fields or fields[0].startswith("#"):
            continue
        if len(fields) != 3:
            raise ConfError(
                f"{path}:{n}: expected '<owner/name|public=*> <include|exclude> <glob>'"
            )
        repo, kind, glob = fields
        is_public = repo == PUBLIC
        if not is_public and not re.fullmatch(r"[A-Za-z0-9._-]+/[A-Za-z0-9._-]+", repo):
            raise ConfError(f"{path}:{n}: '{repo}' is not owner/name")
        if kind not in ("include", "exclude"):
            raise ConfError(f"{path}:{n}: unknown kind '{kind}'")
        if glob.startswith("/") or ".." in glob.split("/"):
            raise ConfError(f"{path}:{n}: glob must be repo-relative: '{glob}'")
        inc, exc = public if is_public else rules.setdefault(repo.lower(), ([], []))
        (inc if kind == "include" else exc).append(glob_to_regex(glob, is_public))
    if not rules and not public[0] and not public[1]:
        # Empty or comment-only reads as "nothing is copy"; fail closed instead.
        raise ConfError(f"{path} has no rules; an empty list would ungate all copy")
    return rules, public


def is_copy(path, inc, exc):
    return any(r.match(path) for r in inc) and not any(r.match(path) for r in exc)


def git(cwd, *args, check=True):
    p = subprocess.run(
        ["git", "-C", cwd, *args],
        check=False,
        capture_output=True,
        stdin=subprocess.DEVNULL,
    )
    if check and p.returncode != 0:
        msg = p.stderr.decode("utf-8", "replace").strip()
        raise RuntimeError(f"git {' '.join(args)} failed: {msg}")
    return p


def repo_of(cwd):
    """Lowercase owner/name from origin, only for a github.com origin."""
    p = git(cwd, "config", "--get", "remote.origin.url", check=False)
    if p.returncode == 1:
        return ""
    if p.returncode != 0:
        msg = p.stderr.decode("utf-8", "replace").strip()
        raise RuntimeError(f"git config --get remote.origin.url failed: {msg}")
    url = p.stdout.decode("utf-8", "replace").strip()
    m = re.match(
        r"^(?:git@github\.com:|(?:https?|ssh|git)://(?:[^@/]+@)?github\.com(?::\d+)?/)"
        r"([^/]+/[^/]+?)(?:\.git)?/?$",
        url,
        re.IGNORECASE,
    )
    return m.group(1).lower() if m else ""


def is_private(repo):
    """True only if `gate-route.sh is-private` exits 0. Public, unknown, or
    a failed call is False: public=* fails closed. Its stderr is dropped,
    since the hook takes our output on success as the extract path."""
    route = os.path.join(os.path.dirname(os.path.realpath(__file__)), "gate-route.sh")
    try:
        p = subprocess.run(
            ["bash", route, "is-private", repo],
            check=False,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=60,
        )
    except (OSError, subprocess.SubprocessError):
        return False
    return p.returncode == 0


def rules_for(repo, rules, public):
    """(includes, excludes) for a lowercase github.com owner/name, or None
    when the repo has no copy paths. public=* lines apply unless the repo is
    proven private; an exclude from either source wins."""
    inc, exc = rules.get(repo, ([], []))
    if repo and (public[0] or public[1]) and not is_private(repo):
        inc, exc = inc + public[0], exc + public[1]
    if not inc and not exc and repo not in rules:
        return None
    return inc, exc


# --- text extraction ---------------------------------------------------------

BLOCK_TAGS = {
    "address", "article", "aside", "blockquote", "body", "br", "button",
    "caption", "dd", "details", "div", "dl", "dt", "fieldset", "figcaption",
    "figure", "footer", "form", "h1", "h2", "h3", "h4", "h5", "h6", "head",
    "header", "hr", "html", "label", "legend", "li", "main", "nav", "ol",
    "option", "p", "pre", "section", "summary", "table", "td", "th", "title",
    "tr", "ul",
}  # fmt: skip
SKIP_TAGS = {"script", "style", "svg", "template"}
TEXT_ATTRS = ("alt", "title", "placeholder", "aria-label")
META_NAMES = re.compile(r"^(description|og:.+|twitter:.+)$", re.IGNORECASE)


class _Text(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.lines = []
        self.buf = []
        self.skip = 0

    def _flush(self):
        text = " ".join("".join(self.buf).split())
        if text:
            self.lines.append(text)
        self.buf = []

    def _attr_text(self, tag, attrs):
        a = {k.lower(): (v or "") for k, v in attrs}
        vals = [a[k] for k in TEXT_ATTRS if a.get(k, "").strip()]
        if tag == "meta" and META_NAMES.match(a.get("name") or a.get("property") or ""):
            vals.append(a.get("content", ""))
        if tag == "input" and a.get("type", "").lower() in ("submit", "button"):
            vals.append(a.get("value", ""))
        for v in vals:
            v = " ".join(v.split())
            if v:
                self._flush()
                self.lines.append(v)

    def handle_starttag(self, tag, attrs):
        if tag in SKIP_TAGS:
            self.skip += 1
            return
        if self.skip:
            return
        if tag in BLOCK_TAGS:
            self._flush()
        self._attr_text(tag, attrs)

    def handle_startendtag(self, tag, attrs):
        if tag in SKIP_TAGS or self.skip:
            return
        if tag in BLOCK_TAGS:
            self._flush()
        self._attr_text(tag, attrs)

    def handle_endtag(self, tag):
        if tag in SKIP_TAGS:
            self.skip = max(0, self.skip - 1)
            return
        if not self.skip and tag in BLOCK_TAGS:
            self._flush()

    def handle_data(self, data):
        if not self.skip:
            self.buf.append(data)


FRONTMATTER = re.compile(r"\A---\r?\n.*?\r?\n---[ \t]*(\r?\n|\Z)", re.DOTALL)
# Drop only real module imports and re-exports; every other line stays copy.
_MDX_CLAUSE = r"([\w$]+(\s*,\s*(\*\s+as\s+[\w$]+|\{[^}]*\}))?|\*\s+as\s+[\w$]+|\{[^}]*\})"
MDX_STATEMENT = re.compile(
    r"^(import\s+(" + _MDX_CLAUSE + r"\s+from\s+)?"
    r"|export\s+(\*(\s+as\s+[\w$]+)?|\{[^}]*\})\s+from\s+)"
    r"['\"][^'\"\s]+['\"]\s*;?$"
)
MD_FM_KEYS = re.compile(
    r"^(title|description|summary|excerpt|subtitle)\s*:\s*(.+)$", re.IGNORECASE
)


def html_text(src, astro=False):
    if astro:
        src = FRONTMATTER.sub("", src, count=1)
    p = _Text()
    p.feed(src)
    p.close()
    p._flush()
    if astro:
        # {expressions} are code. Drop the simple, unnested ones.
        out = []
        for line in p.lines:
            prev = None
            while prev != line:
                prev, line = line, re.sub(r"\{[^{}]*\}", "", line)
            line = " ".join(line.split())
            if line:
                out.append(line)
        return out
    return p.lines


MD_ATTR = re.compile(
    r"\b(?:alt|title|aria-label|placeholder)\s*=\s*(?:\"([^\"]*)\"|'([^']*)')",
    re.IGNORECASE,
)


def _md_attr_text(tag):
    return [a or b for a, b in MD_ATTR.findall(tag) if (a or b).strip()]


def _md_inline(s):
    s = re.sub(r"!\[([^\]]*)\]\([^)]*\)", r"\1", s)
    s = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", s)
    s = re.sub(r"\[([^\]]*)\]\[[^\]]*\]", r"\1", s)
    # A raw HTML tag keeps the text of its alt, title, aria-label and placeholder attributes.
    s = re.sub(r"</?[A-Za-z][^>]*>", lambda m: " " + " ".join(_md_attr_text(m.group(0))) + " ", s)
    s = re.sub(r"(\*\*|__|\*|`)", "", s)
    s = re.sub(r"(^|\W)_(\S.*?\S|\S)_(\W|$)", r"\1\2\3", s)
    return " ".join(s.split())


def md_text(src, mdx=False):
    lines = []
    m = FRONTMATTER.match(src)
    if m:
        for fm in m.group(0).splitlines():
            km = MD_FM_KEYS.match(fm.strip())
            if km:
                v = km.group(2).strip().strip("'\"").strip()
                if v:
                    lines.append(v)
        src = src[m.end() :]
    para = []
    fence = None

    def flush():
        if para:
            t = _md_inline(" ".join(para))
            if t:
                lines.append(t)
            para.clear()

    for raw in src.splitlines():
        s = raw.strip()
        if fence:
            if s.startswith(fence):
                fence = None
            continue
        fm = re.match(r"^(```+|~~~+)", s)
        if fm:
            flush()
            fence = fm.group(1)
            continue
        if not s or re.fullmatch(r"([-*_])( *\1){2,}", s):
            flush()
            continue
        if mdx and MDX_STATEMENT.match(s):
            flush()
            continue
        block = re.match(r"^(#{1,6}\s+|[-*+]\s+|\d+[.)]\s+|>\s?)", s)
        if block:
            flush()
            s = s[block.end() :]
            if block.group(1).startswith(("#", ">")):
                t = _md_inline(s)
                if t:
                    lines.append(t)
                continue
        para.append(s)
    flush()
    return lines


def json_text(src):
    out = []

    def walk(v):
        if isinstance(v, str):
            t = " ".join(v.split())
            if re.search(r"[^\W\d_]", t):
                out.append(t)
        elif isinstance(v, list):
            for x in v:
                walk(x)
        elif isinstance(v, dict):
            for x in v.values():
                walk(x)

    walk(json.loads(src))
    return out


def plain_text(src):
    return [ln.rstrip() for ln in src.splitlines() if ln.strip()]


def to_text(path, data):
    src = data.decode("utf-8", "replace")
    ext = os.path.splitext(path)[1].lower()
    if ext in (".html", ".htm"):
        return html_text(src)
    if ext == ".astro":
        return html_text(src, astro=True)
    if ext in (".md", ".mdx", ".markdown"):
        return md_text(src, mdx=ext == ".mdx")
    if ext == ".json":
        return json_text(src)
    return plain_text(src)


def changed_text(old, new):
    """Lines of `new` that `old` does not have, in order."""
    out = []
    sm = SequenceMatcher(None, old, new, autojunk=False)
    for tag, _i1, _i2, j1, j2 in sm.get_opcodes():
        if tag in ("replace", "insert"):
            out.extend(new[j1:j2])
    return out


# --- commands ----------------------------------------------------------------


def staged_copy(cwd, inc, exc):
    p = git(
        cwd, "diff", "--cached", "--no-renames", "--diff-filter=d", "--name-only", "-z"
    )
    names = [n for n in p.stdout.decode("utf-8", "surrogateescape").split("\0") if n]
    return sorted(n for n in names if is_copy(n, inc, exc))


def build_extract(cwd, paths):
    has_head = (
        git(cwd, "rev-parse", "--verify", "-q", "HEAD", check=False).returncode == 0
    )
    parts = []
    for path in paths:
        new = to_text(path, git(cwd, "show", f":{path}").stdout)
        old_blob = None
        # A path missing from HEAD (cat-file -e fails), or no HEAD, is a new file.
        in_head = has_head and (
            git(cwd, "cat-file", "-e", f"HEAD:{path}", check=False).returncode == 0
        )
        if in_head:
            old_blob = git(cwd, "show", f"HEAD:{path}").stdout
        old = None
        if old_blob is not None:
            try:
                old = to_text(path, old_blob)
            except ValueError:
                # A HEAD version that does not parse must not block the commit that fixes it.
                text, label = new, "old version unreadable, whole text"
        if old is not None:
            text, label = changed_text(old, new), "added or changed text"
        elif old_blob is None:
            text, label = new, "new file, whole text"
        text = [t.rstrip() for t in text if t.strip()]
        if text:
            parts.append("\n".join([f">> {path} ({label})", *text]))
    return "\n\n".join(parts) + "\n" if parts else ""


def prune(out_dir, max_age=7 * 86400):
    now = time.time()
    try:
        names = os.listdir(out_dir)
    except OSError:
        return
    for n in names:
        if re.fullmatch(r"[0-9a-f]{64}\.txt(\.\d+\.tmp)?", n):
            f = os.path.join(out_dir, n)
            try:
                if now - os.stat(f).st_mtime > max_age:
                    os.remove(f)
            except OSError:
                pass


def cmd_extract(argv):
    args = dict(zip(argv[::2], argv[1::2]))
    if len(argv) % 2 or set(args) != {"--dir", "--out-dir"}:
        print(
            "usage: gate-copy.py extract --dir <checkout> --out-dir <dir>",
            file=sys.stderr,
        )
        return 2
    cwd, out_dir = args["--dir"], args["--out-dir"]
    try:
        rules, public = load_conf(conf_path())
    except ConfError as e:
        print(f"gate-copy: {e}", file=sys.stderr)
        return 4
    repo = "?"
    try:
        repo = repo_of(cwd)
        found = rules_for(repo, rules, public) if repo else None
        if found is None:
            return 3
        inc, exc = found
        text = build_extract(cwd, staged_copy(cwd, inc, exc))
    except (RuntimeError, ValueError, OSError) as e:
        print(
            f"gate-copy: cannot extract the copy from {cwd} ({repo}): {e}",
            file=sys.stderr,
        )
        return 5
    if not text:
        return 0
    data = text.encode("utf-8")
    try:
        os.makedirs(out_dir, exist_ok=True)
        prune(out_dir)
        dest = os.path.join(out_dir, hashlib.sha256(data).hexdigest() + ".txt")
        tmp = f"{dest}.{os.getpid()}.tmp"
        with open(tmp, "wb") as f:
            f.write(data)
        os.replace(tmp, dest)
    except OSError as e:
        print(f"gate-copy: cannot write the extract to {out_dir}: {e}", file=sys.stderr)
        try:
            os.unlink(tmp)
        except (OSError, NameError):
            pass
        return 5
    print(dest)
    return 0


def cmd_match(argv):
    if len(argv) < 2 or argv[0] != "--repo":
        print(
            "usage: gate-copy.py match --repo <owner/name> <path>...", file=sys.stderr
        )
        return 2
    try:
        rules, public = load_conf(conf_path())
    except ConfError as e:
        print(f"gate-copy: {e}", file=sys.stderr)
        return 4
    inc, exc = rules_for(argv[1].lower(), rules, public) or ([], [])
    for p in argv[2:]:
        if is_copy(p, inc, exc):
            print(p)
    return 0


def main(argv):
    if argv and argv[0] == "extract":
        return cmd_extract(argv[1:])
    if argv and argv[0] == "match":
        return cmd_match(argv[1:])
    print("usage: gate-copy.py {extract|match} ...", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
