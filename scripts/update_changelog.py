#!/usr/bin/env python3
"""
Foder changelog generator.

Keeps CHANGELOG.md in sync with the commit log, so the changelog is never
something you have to remember to write.

Usage
-----
    python3 scripts/update_changelog.py                   # refresh Unreleased
    python3 scripts/update_changelog.py --release X.Y.Z   # fold into a version
    python3 scripts/update_changelog.py --dry-run         # print, do not write

Layout contract
---------------
* The region between `<!-- CHANGELOG-AUTO:BEGIN -->` and
  `<!-- CHANGELOG-AUTO:END -->` holds the **Unreleased** list and is rewritten
  on every run. It starts empty at the commit recorded in `<!-- auto:base=... -->`
  and grows with each new commit.
* Everything outside that region — including every hand-written release
  section — is preserved byte for byte.
* `--release X.Y.Z` moves the Unreleased list into a `## X.Y.Z — <date>` section
  placed immediately after the auto block, then advances the base marker to HEAD.
* The script only writes files. It never rewrites or amends git history.

Wired up in two places on purpose:
* `.githooks/post-commit`            — runs locally right after you commit
* `.github/workflows/changelog.yml`  — runs in CI on every push and commits the
  result back, so contributors who did not install the hooks are covered too.
"""

from __future__ import annotations

import argparse
import datetime as _dt
import re
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
CHANGELOG = REPO_ROOT / "CHANGELOG.md"

BEGIN_MARK = "<!-- CHANGELOG-AUTO:BEGIN -->"
END_MARK   = "<!-- CHANGELOG-AUTO:END -->"

# Conventional commit type -> section title, in display order.
SECTIONS: list[tuple[str, str]] = [
    ("feat",     "Added"),
    ("fix",      "Fixed"),
    ("perf",     "Performance"),
    ("refactor", "Changed"),
    ("docs",     "Documentation"),
    ("test",     "Tests"),
    ("build",    "Build"),
    ("ci",       "CI"),
    ("style",    "Style"),
    ("chore",    "Chores"),
    ("revert",   "Reverts"),
]

COMMIT_RE = re.compile(
    r"^(?P<type>[a-z]+)(?:\((?P<scope>[^)]+)\))?(?P<breaking>!)?:\s*(?P<subject>.+)$"
)
# Commits produced by this automation itself — never listed.
SELF_PREFIXES = ("chore(changelog)", "chore: changelog", "chore: auto-update changelog")

BASE_RE = re.compile(r"<!-- auto:base=([0-9a-f]{7,40}|none) -->")


def _git(args: list[str]) -> str:
    out = subprocess.run(["git"] + args, cwd=str(REPO_ROOT),
                         capture_output=True, text=True, timeout=120)
    return out.stdout if out.returncode == 0 else ""


def _is_ancestor(sha: str, ref: str = "HEAD") -> bool:
    out = subprocess.run(["git", "merge-base", "--is-ancestor", sha, ref],
                         cwd=str(REPO_ROOT), capture_output=True, timeout=120)
    return out.returncode == 0


def _sha_exists(sha: str) -> bool:
    """Return True if the SHA is reachable in the repository (handles post-amend orphans)."""
    out = subprocess.run(["git", "cat-file", "-e", sha],
                         cwd=str(REPO_ROOT), capture_output=True, timeout=120)
    return out.returncode == 0


def read_base(text: str) -> str | None:
    m = BASE_RE.search(text)
    if not m or m.group(1) == "none":
        return None
    sha = m.group(1)
    # If the SHA no longer exists (e.g. was rewritten by a local --amend),
    # fall back to HEAD's parent so we only pick up the most recent commit
    # rather than dumping the entire history into Unreleased.
    if not _sha_exists(sha):
        parent = _git(["rev-parse", "HEAD~1"]).strip()
        return parent if parent else None
    return sha if _is_ancestor(sha) else None


def _commits(since: str | None) -> list[dict]:
    fmt = "%H%x1f%h%x1f%ad%x1f%an%x1f%s"
    args = ["log", "--date=short", f"--pretty=format:{fmt}"]
    if since:
        args.append(f"{since}..HEAD")
    rows: list[dict] = []
    for line in _git(args).splitlines():
        parts = line.split("\x1f")
        if len(parts) != 5:
            continue
        sha, short, date, author, subject = parts
        if any(subject.startswith(p) for p in SELF_PREFIXES) or "skip-changelog" in subject:
            continue
        rows.append({"sha": sha, "short": short, "date": date,
                     "author": author, "subject": subject})
    return rows


def _group(commits: list[dict]) -> list[tuple[str, list[dict]]]:
    buckets: dict[str, list[dict]] = {}
    for c in commits:
        m = COMMIT_RE.match(c["subject"])
        if not m:
            buckets.setdefault("other", []).append(c)
            continue
        kind = "feat" if m.group("breaking") else m.group("type")
        scope = m.group("scope")
        if scope:
            c = dict(c, scope=scope)
        buckets.setdefault(kind, []).append(c)

    out: list[tuple[str, list[dict]]] = []
    for kind, title in SECTIONS:
        if kind in buckets:
            out.append((title, buckets.pop(kind)))
    if "other" in buckets:
        out.append(("Other", buckets.pop("other")))
    return out


def _render_section(heading: str, commits: list[dict]) -> str:
    lines = [f"## {heading}", ""]
    if not commits:
        lines += ["_No changes recorded yet._", ""]
        return "\n".join(lines)
    for title, items in _group(commits):
        lines.append(f"### {title}")
        lines.append("")
        for c in items:
            subject = COMMIT_RE.sub(lambda m: m.group("subject"), c["subject"]).strip()
            subject = subject[0].upper() + subject[1:] if subject else subject
            scope = c.get("scope")
            prefix = f"**{scope}**: " if scope else ""
            lines.append(f"- {prefix}{subject} ({c['short']})")
        lines.append("")
    return "\n".join(lines)


def build_auto_block(commits: list[dict], base: str | None) -> str:
    today = _dt.date.today().isoformat()
    parts = [
        BEGIN_MARK,
        "",
        _render_section("Unreleased", commits).rstrip(),
        "",
        f"<!-- auto:base={base or 'none'} -->",
        f"<!-- auto:generated={today} · regenerate: python3 scripts/update_changelog.py -->",
        "",
        END_MARK,
    ]
    return "\n".join(parts)


def _split(text: str) -> tuple[str, str, str] | None:
    pattern = re.compile(
        r"(?P<pre>.*?)" + re.escape(BEGIN_MARK) + r".*?" + re.escape(END_MARK) + r"(?P<post>.*)",
        re.DOTALL,
    )
    m = pattern.match(text)
    if not m:
        return None
    return m.group("pre"), m.group("post")


def refresh(text: str) -> str:
    """Rewrite only the Unreleased block."""
    base = read_base(text)
    commits = _commits(base)
    block = build_auto_block(commits, base)
    parts = _split(text)
    if parts is None:
        # First run: seed the base with the current commit so the block starts
        # empty — historical commits are already described further down.
        head = _git(["rev-parse", "HEAD"]).strip() or "none"
        block = build_auto_block([], head)
        lines = text.splitlines()
        idx = next((i + 1 for i, l in enumerate(lines[:20]) if l.startswith("# ")), 0)
        return "\n".join(lines[:idx] + block.splitlines() + [""] + lines[idx:])
    pre, post = parts
    # Keep the blank-line separation the author had around the markers.
    pre = pre.rstrip("\n") + "\n\n"
    post = post.lstrip("\n")
    return pre + block + ("\n\n" + post if post.strip() else "")


def release(text: str, version: str) -> str:
    """Fold Unreleased into a version section directly below the auto block."""
    base = read_base(text)
    commits = _commits(base)
    if not commits:
        print(f"note: no commits since base {base or 'none'} — section will be empty")
    section = _render_section(f"{version} — {_dt.date.today().isoformat()}", commits).rstrip()
    head = _git(["rev-parse", "HEAD"]).strip() or "none"
    block = build_auto_block([], head)

    parts = _split(text)
    if parts is None:
        lines = text.splitlines()
        idx = next((i + 1 for i, l in enumerate(lines[:20]) if l.startswith("# ")), 0)
        return "\n".join(lines[:idx] + block.splitlines() + [""] + section.splitlines() + lines[idx:])

    pre, post = parts
    pre = pre.rstrip("\n") + "\n\n"
    post = post.lstrip("\n")
    body = pre + block + "\n\n" + section
    if post.strip():
        body += "\n\n" + post
    return body


def main() -> int:
    ap = argparse.ArgumentParser(description="Regenerate the Foder changelog block.")
    ap.add_argument("--release", metavar="VERSION", default=None,
                    help="fold commits since the base into a released version section")
    ap.add_argument("--dry-run", action="store_true",
                    help="print the result instead of writing it")
    args = ap.parse_args()

    if not CHANGELOG.exists():
        print(f"error: {CHANGELOG} not found", file=sys.stderr)
        return 1

    text = CHANGELOG.read_text(encoding="utf-8")
    new = release(text, args.release) if args.release else refresh(text)

    if args.dry_run:
        print(new)
        return 0
    if new != text:
        CHANGELOG.write_text(new, encoding="utf-8")
        print(f"updated {CHANGELOG.relative_to(REPO_ROOT)}")
    else:
        print("changelog already up to date")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
