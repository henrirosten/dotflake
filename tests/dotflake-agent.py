"""Offline black-box tests of the packaged host and guest transport commands."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest


class Transport(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.host = self.root / "host"
        self.guest = self.root / "guest"
        self.env = {key: value for key, value in os.environ.items()
                    if not key.startswith("GIT_")}
        self.env.update(
            HOME=str(self.root / "home"),
            XDG_STATE_HOME=str(self.root / "state"),
            GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL="/dev/null",
            GIT_OPTIONAL_LOCKS="0", LC_ALL="C",
        )
        Path(self.env["HOME"]).mkdir()
        self.repository(self.host)
        self.initial = self.git(self.host, "rev-parse", "HEAD").strip()

    def run_command(self, *args, input=None, success=True):
        result = subprocess.run(
            args, cwd=self.root, env=self.env, input=input,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=20,
        )
        if success:
            self.assertEqual(result.returncode, 0, (args, result.stdout, result.stderr))
        else:
            self.assertNotEqual(result.returncode, 0, (args, result.stdout, result.stderr))
        return result

    def git_bytes(self, path, *args, **kwargs):
        return self.run_command("git", "-C", str(path), *args, **kwargs).stdout

    def git(self, path, *args, **kwargs):
        return self.git_bytes(path, *args, **kwargs).decode()

    def repository(self, path):
        self.run_command("git", "init", "-b", "main", str(path))
        self.identity(path)
        (path / "tracked").write_text("initial\n")
        self.git(path, "add", ".")
        self.git(path, "commit", "-m", "Initial commit")

    def identity(self, path):
        self.git(path, "config", "user.name", "Transport test")
        self.git(path, "config", "user.email", "transport@example.invalid")

    def helper(self, command, *options, success=True):
        return self.run_command("dotflake-agent", command, "--instance", "test",
                                "--project", str(self.host), *options, success=success)

    def instance(self):
        projects = list((self.root / "state/dotflake/agents").iterdir())
        self.assertEqual(len(projects), 1)
        return projects[0] / "instances/test"

    def init_guest(self, *branches):
        self.helper("push", *[option for branch in branches for option in ("--branch", branch)])
        self.run_command("agent-init", str(self.guest), str(self.instance() / "inbox"))
        self.identity(self.guest)

    def export(self):
        return self.run_command("agent-export", str(self.guest), str(self.instance() / "outbox"))

    def ref(self, name, path=None):
        return self.git(path or self.host, "rev-parse", "--verify", name).strip()

    def refs(self):
        return self.git_bytes(self.host, "for-each-ref",
                              "--format=%(refname) %(objectname)")

    def checkout_state(self, path):
        index = Path(self.git(path, "rev-parse", "--path-format=absolute", "--git-path", "index").strip())
        return (self.git_bytes(path, "rev-parse", "HEAD"), index.read_bytes(),
                self.git_bytes(path, "status", "--porcelain"))

    def marker_hooks(self):
        file_marker = self.root / "file-hook-ran"
        config_marker = self.root / "config-hook-ran"
        hook = self.host / ".git/hooks/reference-transaction"
        hook.write_text(f"#!/bin/sh\ntouch '{file_marker}'\n")
        hook.chmod(0o755)
        self.git(self.host, "config", "hook.test.event", "reference-transaction")
        self.git(self.host, "config", "hook.test.command", f"touch '{config_marker}'")
        self.git(self.host, "update-ref", "refs/heads/probe", self.initial)
        for marker in (file_marker, config_marker):
            self.assertTrue(marker.exists())
            marker.unlink()
        return file_marker, config_marker

    def test_round_trip(self):
        markers = self.marker_hooks()
        (self.host / "tracked").write_text("host staged\n")
        self.git(self.host, "add", "tracked")
        (self.host / "tracked").write_text("host unstaged\n")
        (self.host / "host-only").write_text("do not send me\n")
        before = self.checkout_state(self.host)
        self.init_guest()
        self.assertFalse((self.guest / "host-only").exists())
        (self.guest / "tracked").write_text("guest commit\n")
        self.git(self.guest, "commit", "-am", "Guest change")
        head = self.ref("HEAD", self.guest)
        self.git(self.guest, "branch", "feature")
        (self.guest / "tracked").write_text("guest staged\n")
        self.git(self.guest, "add", "tracked")
        (self.guest / "tracked").write_text("guest unstaged\n")
        (self.guest / "untracked").write_text("new file\n")
        guest_before = self.checkout_state(self.guest)
        self.export()
        self.assertEqual(guest_before, self.checkout_state(self.guest))
        wip = self.ref("refs/export/wip", self.guest)
        self.assertEqual(self.ref(f"{wip}^", self.guest), head)
        self.helper("import")
        for branch in ("main", "feature"):
            self.assertEqual(self.ref(f"refs/remotes/vm-test/heads/{branch}"), head)
        self.assertEqual(self.ref("refs/remotes/vm-test/wip"), wip)
        self.assertEqual(self.git(self.host, "show", f"{wip}:tracked"), "guest unstaged\n")
        self.assertEqual(self.git(self.host, "show", f"{wip}:untracked"), "new file\n")
        self.assertEqual(before, self.checkout_state(self.host))
        for marker in markers:
            self.assertFalse(marker.exists())

    def test_push_excludes_unselected_history(self):
        self.assertIn(b"/instances/default/inbox", self.run_command(
            "dotflake-agent", "push", "--project", str(self.host),
        ).stdout)
        self.git(self.host, "branch", "other")
        (self.host / "tracked").write_text("main-only change\n")
        self.git(self.host, "commit", "-am", "Main-only commit")
        main_only = self.ref("HEAD")
        self.init_guest("other")
        bundle = self.instance() / "inbox/host.bundle"
        self.assertEqual(self.git(self.host, "bundle", "list-heads", str(bundle)),
                         f"{self.initial} refs/heads/other\n")
        self.git(self.guest, "cat-file", "-e", f"{main_only}^{{commit}}", success=False)

    def bundle(self, *refs):
        target = self.root / "fixture.bundle"
        target.unlink(missing_ok=True)
        self.git(self.guest, "bundle", "create", str(target), *refs)
        return target.read_bytes()

    def raw_bundle(self, oid, ref):
        objects = [line.split(" ", 1)[0] for line in self.git(self.guest, "rev-list", "--objects", "HEAD").splitlines()]
        packed = self.git_bytes(self.guest, "pack-objects", "--stdout",
                                input=("\n".join([oid, *objects]) + "\n").encode())
        return f"# v2 git bundle\n{oid} {ref}\n\n".encode() + packed

    def test_bundle_rejections_are_atomic(self):
        self.init_guest()
        self.export()
        self.helper("import")
        (self.guest / "tracked").write_text("second commit\n")
        self.git(self.guest, "commit", "-am", "Second commit")
        self.export()
        target = self.instance() / "outbox/export.bundle"
        valid = target.read_bytes()
        self.git(self.guest, "tag", "forbidden")
        self.git(self.guest, "update-ref", "refs/custom/forbidden", self.ref("HEAD", self.guest))
        blob = self.git(self.guest, "hash-object", "-w", "--stdin", input=b"a blob\n").strip()
        tree = self.ref("HEAD^{tree}", self.guest)
        invalid = self.git(self.guest, "hash-object", "--literally", "-w", "-t", "commit", "--stdin",
                           input=f"tree {tree}\n\nMissing author and committer\n".encode()).strip()
        fixtures = {
            "truncated-header": b"# v2 git bundle\n",
            "truncated-pack": valid[:-30],
            "prerequisites": self.bundle("refs/heads/main", "^" + self.initial),
            "tag": self.bundle("refs/tags/forbidden"),
            "HEAD": self.bundle("HEAD"),
            "outside-contract": self.bundle("refs/custom/forbidden"),
            "invalid-ref": valid.replace(b"refs/heads/main\n", b"refs/heads/bad..name\n", 1),
            "nul-ref": valid.replace(b"refs/heads/main\n", b"refs/heads/bad\x00name\n", 1),
            "non-commit": self.raw_bundle(blob, "refs/export/wip"),
            "fsck": self.raw_bundle(invalid, "refs/heads/broken"),
            "filter": valid.replace(b"# v2 git bundle\n", b"# v3 git bundle\n@object-format=sha1\n@filter=blob:none\n", 1),
            "object-format": valid.replace(b"# v2 git bundle\n", b"# v3 git bundle\n@object-format=sha256\n", 1),
            "bad-signature": valid.replace(b"# v2 git bundle", b"# v1 git bundle", 1),
            "v3": valid.replace(b"# v2 git bundle", b"# v3 git bundle", 1),
            "long-oid": valid.replace(self.ref("HEAD", self.guest).encode(), b"a" * 64, 1),
            "v2-capability": valid.replace(b"# v2 git bundle\n", b"# v2 git bundle\n@object-format=sha256\n", 1),
        }
        for name, contents in fixtures.items():
            with self.subTest(fixture=name):
                target.write_bytes(contents)
                before = self.refs()
                checkout = self.checkout_state(self.host)
                self.helper("import", success=False)
                self.assertEqual(before, self.refs())
                self.assertEqual(checkout, self.checkout_state(self.host))
        target.write_bytes(valid)
        before = self.refs()
        result = self.helper("import", "--max-bytes", str(len(valid) - 1), success=False)
        self.assertIn(b"size limit", result.stderr)
        self.assertEqual(before, self.refs())

        original = self.root / "original.bundle"
        target.rename(original)
        for kind, error in (("symlink", b"Too many levels of symbolic links"),
                            ("fifo", b"export.bundle must be a regular file"),
                            ("directory", b"Is a directory")):
            with self.subTest(kind=kind):
                if kind == "symlink":
                    target.symlink_to(original)
                elif kind == "fifo":
                    os.mkfifo(target)
                else:
                    target.mkdir()
                before = self.refs()
                result = self.helper("import", success=False)
                self.assertIn(error, result.stderr)
                self.assertEqual(before, self.refs())
                if kind == "directory":
                    target.rmdir()
                else:
                    target.unlink()

        self.git(self.guest, "branch", "collision")
        target.write_bytes(self.bundle("--branches", "refs/export/wip"))
        self.git(self.host, "update-ref", "refs/remotes/vm-test/heads/collision/child", self.initial)
        before = self.refs()
        self.helper("import", success=False)
        self.assertEqual(before, self.refs())


if __name__ == "__main__":
    unittest.main(verbosity=2)
