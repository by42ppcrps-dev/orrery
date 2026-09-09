#!/usr/bin/env python3
"""Refuse to publish personal data.

  public_guard.py --tree [REV]          scan every file in the tree at REV (default HEAD)
  public_guard.py --history [REV]       scan every reachable version and commit identity
  public_guard.py --pre-push NAME URL   git pre-push hook: reads the ref updates git passes on
                                        stdin and guards only the remote named "public"
                                        (set ORRERY_GUARD_ALL=1 to guard every remote)

What is refused: files under an evidence folder (docs/verification-*, scratchpad/), home paths
other than the neutral ones, signing team ids and identities, provider tokens, private keys,
credential URLs, and any term listed one per line in the terms file (ORRERY_GUARD_TERMS, default
.public-guard-terms at the repository root, which is ignored by git and never published). The
current user's home folder name is always a term. Commits are also checked: author and committer
must be the identity this checkout is configured with, and messages are scanned like files.
Output names files, commits and categories only; matching text is never printed.
"""
import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True).stdout.strip() or ".")
NEUTRAL_HOMES = {"runner", "user", "developer", "someone", "root", "me", "Shared", "shared"}
BINARY = {".png", ".jpg", ".jpeg", ".gif", ".icns", ".zip", ".mov", ".mp4", ".tgz", ".gz"}
PUBLIC_ASSETS = {"Resources/AppIcon.icns", "docs/images/studio-solo.png", "docs/images/command-palette.png",
                 "docs/images/roundtable.png", "docs/images/team.png",
                 "Remote/OrreryRemote/OrreryRemote/Assets.xcassets/AppIcon.appiconset/icon-1024.png"}
PRIVATE_FILES = {".public-guard-terms", "auth.json", "credentials.json", "connectors.json", ".env"}
PUBLIC_REPOSITORY = "github.com/by42ppcrps-dev/orrery"
PATTERNS = {
    # Literals are split so this file passes its own scan.
    "private-home-path": re.compile("/" + r"Users/(?!(?:Shared|shared|someone|developer|me|runner|user|root)(?:/|\b))[^/\s\"']+"),
    "private-key": re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"),
    "provider-token": re.compile(r"\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,}|sk-(?:proj-|ant-)?[A-Za-z0-9_-]{32,}|xai-[A-Za-z0-9_-]{32,}|AKIA[0-9A-Z]{16})\b"),
    "personal-signing-team": re.compile(r"(?:DEVELOPMENT" + r"_TEAM\s*=\s*[A-Z0-9]{10}\b|<key>teamID</key>\s*<string>[A-Z0-9]{10}</string>|TeamIdentifier=[A-Z0-9]{10}\b)"),
    "embedded-signing-identity": re.compile(r"Apple (?:Development|Distribution): [^\"\n]+\([A-Z0-9]{10}\)"),
    "credential-url": re.compile(r"https?://[^/\s\"']+:[^/\s\"']+@(?!evil\.example)"),
    "relay-email": re.compile(r"[A-Za-z0-9._%+-]+@private" + r"relay\.appleid\.com"),
}
EVIDENCE_PREFIXES = ("docs/verification-", "scratchpad/", "build/", ".build/")


def terms_path():
    return Path(os.environ.get("ORRERY_GUARD_TERMS") or ROOT / ".public-guard-terms")


def load_terms():
    terms = set()
    home = Path.home().name
    if home not in NEUTRAL_HOMES:
        terms.add(home)
    path = terms_path()
    if path.is_file():
        for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
            line = line.strip()
            if line and not line.startswith("#"):
                terms.add(line)
    return sorted(terms, key=len, reverse=True)


def term_pattern(terms):
    if not terms:
        return None
    return re.compile(r"(?<![\w])(?:" + "|".join(re.escape(t) for t in terms) + r")(?![\w])", re.I)


FIXTURE_CREDENTIAL = re.compile(r"https?://user:(?:pw|secret)@")


def scan_text(text, terms_re, where, findings):
    for category, pattern in PATTERNS.items():
        matches = [m for m in pattern.finditer(text)]
        if category == "credential-url" and "/Audit/" in where:
            matches = [m for m in matches if not FIXTURE_CREDENTIAL.match(m.group())]  # synthetic fixtures
        if matches:
            findings.append((where, category))
    # The published repository address is necessary for installation and update checks.
    # Permit only that exact path; the same identity elsewhere is still private.
    public_path = "/" + PUBLIC_REPOSITORY.split("/", 1)[1]
    if terms_re and terms_re.search(text.replace(public_path, "/public-repository")):
        findings.append((where, "private-term"))


def git(*args, binary=False):
    result = subprocess.run(["git", *args], capture_output=True, cwd=ROOT)
    if result.returncode != 0:
        raise SystemExit("public guard: git " + " ".join(args) + " failed: " + result.stderr.decode(errors="replace").strip())
    return result.stdout if binary else result.stdout.decode("utf-8", errors="replace")


def scan_tree(rev, terms_re, findings):
    entries = [n for n in git("ls-tree", "-r", "-z", rev).split("\0") if n]
    for entry in entries:
        metadata, name = entry.split("\t", 1)
        mode, kind, _ = metadata.split()
        if mode == "120000" or kind != "blob":
            findings.append((name, "symbolic-link" if mode == "120000" else "unscanned-submodule"))
            continue
        basename = Path(name).name
        if (name.startswith(EVIDENCE_PREFIXES) or "/xcuserdata/" in name
                or name.endswith((".p12", ".mobileprovision", ".provisionprofile"))
                or basename in PRIVATE_FILES or basename.startswith(".env.") and basename != ".env.example"):
            findings.append((name, "private-evidence"))
        if Path(name).suffix.lower() in BINARY and name not in PUBLIC_ASSETS:
            findings.append((name, "unreviewed-binary"))
        data = git("show", f"{rev}:{name}", binary=True)
        try:
            text = data.decode("utf-8")
            binary = "\0" in text
        except UnicodeDecodeError:
            text = data.decode("utf-8", errors="replace")
            binary = True
        if binary and name not in PUBLIC_ASSETS:
            findings.append((name, "unreviewed-binary"))
        scan_text(name, terms_re, name, findings)
        scan_text(text, terms_re, name, findings)
    return len(entries)


def allowed_identity():
    name = git("config", "user.name").strip()
    email = git("config", "user.email").strip()
    return name, email


def scan_commits(range_spec, terms_re, findings):
    name, email = allowed_identity()
    raw = git("log", "--format=%H%x00%an%x00%ae%x00%cn%x00%ce%x00%B%x01", range_spec)
    count = 0
    for record in raw.split("\x01"):
        if not record.strip():
            continue
        parts = record.lstrip("\n").split("\x00")
        if len(parts) < 6:
            continue
        sha, an, ae, cn, ce, body = parts[0][:10], parts[1], parts[2], parts[3], parts[4], parts[5]
        count += 1
        if (an, ae) != (name, email) or (cn, ce) != (name, email):
            findings.append((f"commit {sha}", "unexpected-identity"))
        scan_text("\n".join([an, ae, cn, ce]), terms_re, f"commit {sha} identity", findings)
        scan_text(body, terms_re, f"commit {sha}", findings)
        # Deleted files and earlier versions are still public through Git history.
        scan_tree(parts[0], terms_re, findings)
    return count


def report(findings):
    seen = []
    for item in findings:
        if item not in seen:
            seen.append(item)
    for where, category in seen:
        print(f"  {where}: {category}", file=sys.stderr)


def main(argv):
    terms_re = term_pattern(load_terms())
    if argv[:1] == ["--history"]:
        rev = argv[1] if len(argv) > 1 else "HEAD"
        findings = []
        count = scan_commits(rev, terms_re, findings)
        if findings:
            print("public guard: history refused", file=sys.stderr)
            report(findings)
            return 1
        print(f"public guard: history is clean ({count} commits)")
        return 0
    if argv[:1] == ["--tree"]:
        rev = argv[1] if len(argv) > 1 else "HEAD"
        findings = []
        n = scan_tree(rev, terms_re, findings)
        if findings:
            print(f"public guard: refused, {len(findings)} finding(s) in the tree at {rev}:", file=sys.stderr)
            report(findings)
            return 1
        print(f"public guard: tree at {rev} is clean ({n} files)")
        return 0
    if argv[:1] == ["--pre-push"]:
        remote = argv[1] if len(argv) > 1 else ""
        url = (argv[2] if len(argv) > 2 else "").removesuffix(".git").replace("git@github.com:", "github.com/")
        public_url = url.removeprefix("https://").removeprefix("ssh://git@") == PUBLIC_REPOSITORY
        if remote != "public" and not public_url and os.environ.get("ORRERY_GUARD_ALL") != "1":
            return 0
        findings = []
        checked = 0
        for line in sys.stdin.read().splitlines():
            fields = line.split()
            if len(fields) != 4:
                print("public guard: malformed ref update", file=sys.stderr)
                return 1
            local_ref, local_sha, remote_ref, remote_sha = fields
            if set(local_sha) == {"0"}:
                continue  # a deletion publishes nothing
            if not terms_path().is_file() or terms_path().is_symlink():
                print("public guard: missing or unsafe private terms file; restore it before publishing", file=sys.stderr)
                return 1
            if any(ref.rsplit("/", 1)[-1] in {"history", "private-history"} for ref in [local_ref, remote_ref]):
                findings.append((remote_ref, "private-history"))
                continue
            checked += scan_tree(local_sha, terms_re, findings)
            range_spec = local_sha if set(remote_sha) == {"0"} else f"{remote_sha}..{local_sha}"
            try:
                scan_commits(range_spec, terms_re, findings)
            except SystemExit:
                scan_commits(local_sha, terms_re, findings)  # remote tip unknown locally: check everything
        if findings:
            print(f"public guard: push to '{remote}' refused, {len(findings)} finding(s):", file=sys.stderr)
            report(findings)
            return 1
        print(f"public guard: push to '{remote}' is clean ({checked} files checked)")
        return 0
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
