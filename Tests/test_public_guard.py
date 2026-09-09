"""The public guard refuses personal data before it can reach the public remote."""
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

GUARD = Path(__file__).resolve().parents[1] / "scripts" / "public_guard.py"
# Split so this file passes the guard it tests.
HOME = "/Us" + "ers/"
TEAM = "DEVELOPMENT" + "_TEAM"


class PublicGuardTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory(prefix="orrery-guard-")
        self.root = Path(self.dir.name)
        self.git("init", "-q", "-b", "main")
        self.git("config", "user.name", "someone")
        self.git("config", "user.email", "someone@example.com")
        self.git("config", "commit.gpgsign", "false")
        self.outside = tempfile.TemporaryDirectory(prefix="orrery-guard-terms-")
        self.terms = Path(self.outside.name) / "terms.txt"   # outside the repo: the guard would refuse it inside
        self.terms.write_text("hidden-person\nAB12CD34EF\n")
        (self.root / "README.md").write_text("Clean project. Paths like /Users/someone/x are neutral.\n")
        self.git("add", "-A")
        self.git("commit", "-q", "-m", "clean start")

    def tearDown(self):
        self.dir.cleanup()
        self.outside.cleanup()

    def git(self, *args):
        return subprocess.run(["git", *args], cwd=self.root, capture_output=True, text=True, check=True).stdout

    def guard(self, *args, stdin=""):
        env = {**os.environ, "ORRERY_GUARD_TERMS": str(self.terms)}
        return subprocess.run(["python3", str(GUARD), *args], cwd=self.root, capture_output=True, text=True, input=stdin, env=env)

    def commit(self, name, text, message="update"):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        self.git("add", "-A")
        self.git("commit", "-q", "-m", message)

    def push_line(self):
        sha = self.git("rev-parse", "HEAD").strip()
        return f"refs/heads/main {sha} refs/heads/main {'0' * 40}\n"

    def test_clean_tree_passes(self):
        result = self.guard("--tree", "HEAD")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("clean", result.stdout)

    def test_history_command_detects_private_metadata(self):
        self.assertEqual(self.guard("--history", "HEAD").returncode, 0)
        self.git("config", "user.email", "person@private" + "relay.appleid.com")
        self.commit("notes.txt", "safe")
        result = self.guard("--history", "HEAD")
        self.assertEqual(result.returncode, 1)
        self.assertIn("relay-email", result.stderr)

    def test_public_repository_address_does_not_allow_the_identity_elsewhere(self):
        identity = "by42" + "ppcrps-dev"
        self.terms.write_text(identity + "\n")
        self.commit("release.md", "https://github.com/" + identity + "/orrery/releases/latest")
        self.assertEqual(self.guard("--tree", "HEAD").returncode, 0)
        self.commit("identity.md", identity)
        result = self.guard("--tree", "HEAD")
        self.assertEqual(result.returncode, 1)
        self.assertIn("private-term", result.stderr)

    def test_unknown_binary_and_malformed_push_are_refused(self):
        (self.root / "local.cache").write_bytes(b"cache\x00private")
        self.git("add", "-A"); self.git("commit", "-q", "-m", "binary")
        result = self.guard("--tree", "HEAD")
        self.assertEqual(result.returncode, 1)
        self.assertIn("unreviewed-binary", result.stderr)
        self.assertEqual(self.guard("--pre-push", "public", "u", stdin="incomplete\n").returncode, 1)

    def test_home_path_is_refused(self):
        self.commit("notes.md", "log at " + HOME + "alice/Library/Logs/x.txt\n")
        result = self.guard("--tree", "HEAD")
        self.assertEqual(result.returncode, 1)
        self.assertIn("private-home-path", result.stderr)
        self.assertNotIn("alice", result.stderr, "matching text must never be printed")

    def test_evidence_folder_is_refused(self):
        self.commit("docs/verification-x/run.log", "anything\n")
        result = self.guard("--tree", "HEAD")
        self.assertEqual(result.returncode, 1)
        self.assertIn("private-evidence", result.stderr)

    def test_term_from_the_terms_file_is_refused(self):
        self.commit("docs/a.md", "Thanks to Hidden-Person for the report.\n")
        result = self.guard("--tree", "HEAD")
        self.assertEqual(result.returncode, 1)
        self.assertIn("private-term", result.stderr)

    def test_term_inside_a_longer_word_is_not_a_hit(self):
        self.commit("docs/a.md", "unhidden-personal\n")
        self.assertEqual(self.guard("--tree", "HEAD").returncode, 0)

    def test_signing_team_is_refused(self):
        self.commit("x.pbxproj", TEAM + " = AB12CD34EF;\n")
        result = self.guard("--tree", "HEAD")
        self.assertEqual(result.returncode, 1)
        self.assertIn("personal-signing-team", result.stderr)

    def test_commit_message_is_scanned_on_push(self):
        self.commit("docs/b.md", "fine\n", message="reviewed with hidden-person")
        result = self.guard("--pre-push", "public", "https://example.invalid/r.git", stdin=self.push_line())
        self.assertEqual(result.returncode, 1)
        self.assertIn("private-term", result.stderr)
        self.assertIn("commit ", result.stderr)

    def test_other_identity_is_refused_on_push(self):
        self.git("config", "user.email", "other@example.com")
        self.commit("docs/c.md", "fine\n")
        self.git("config", "user.email", "someone@example.com")
        result = self.guard("--pre-push", "public", "https://example.invalid/r.git", stdin=self.push_line())
        self.assertEqual(result.returncode, 1)
        self.assertIn("unexpected-identity", result.stderr)

    def test_clean_push_passes_and_other_remotes_are_not_guarded(self):
        self.commit("docs/d.md", "fine\n")
        self.assertEqual(self.guard("--pre-push", "public", "u", stdin=self.push_line()).returncode, 0)
        self.commit("docs/e.md", HOME + "alice/private\n")
        self.assertEqual(self.guard("--pre-push", "origin", "u", stdin=self.push_line()).returncode, 0)
        self.assertEqual(self.guard("--pre-push", "public", "u", stdin=self.push_line()).returncode, 1)

    def test_a_committed_terms_file_is_refused(self):
        self.commit(".public-guard-terms", "hidden-person\n")
        result = self.guard("--tree", "HEAD")
        self.assertEqual(result.returncode, 1)
        self.assertIn("private-term", result.stderr)

    def test_deleting_a_remote_branch_publishes_nothing(self):
        line = f"(delete) {'0' * 40} refs/heads/old {'1' * 40}\n"
        self.assertEqual(self.guard("--pre-push", "public", "u", stdin=line).returncode, 0)

    def test_deleted_secret_in_intermediate_commit_is_refused(self):
        base = self.git("rev-parse", "HEAD").strip()
        self.commit("temporary.txt", "hidden-person")
        self.git("rm", "temporary.txt")
        self.git("commit", "-q", "-m", "remove temporary file")
        line = self.push_line().replace('0' * 40, base)
        result = self.guard("--pre-push", "public", "u", stdin=line)
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("private-term", result.stderr)

    def test_public_push_requires_private_terms_file(self):
        self.terms.unlink()
        result = self.guard("--pre-push", "public", "u", stdin=self.push_line())
        self.assertEqual(result.returncode, 1)
        self.assertIn("terms file", result.stderr)

    def test_private_history_branch_is_never_published(self):
        line = self.push_line().replace("refs/heads/main", "refs/heads/history")
        result = self.guard("--pre-push", "public", "u", stdin=line)
        self.assertEqual(result.returncode, 1)
        self.assertIn("private-history", result.stderr)

    def test_public_url_is_guarded_even_with_another_remote_name(self):
        self.commit("temporary.txt", "hidden-person")
        result = self.guard("--pre-push", "renamed", "https://github.com/by42ppcrps-dev/orrery.git", stdin=self.push_line())
        self.assertEqual(result.returncode, 1)

    def test_local_account_files_and_archives_are_refused(self):
        for name in [".env.local", "auth.json", "connectors.json", "backup.zip", ".public-guard-terms"]:
            with self.subTest(name=name):
                self.commit(name, "innocent-looking content")
                self.assertEqual(self.guard("--tree", "HEAD").returncode, 1)
                self.git("rm", name)
                self.git("commit", "-q", "-m", "remove fixture")

    def test_symlink_is_refused(self):
        (self.root / "linked.txt").symlink_to("README.md")
        self.git("add", "linked.txt")
        self.git("commit", "-q", "-m", "link fixture")
        result = self.guard("--tree", "HEAD")
        self.assertEqual(result.returncode, 1)
        self.assertIn("symbolic-link", result.stderr)


if __name__ == "__main__":
    unittest.main()
