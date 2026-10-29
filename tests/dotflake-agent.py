"""Offline black-box tests of the packaged host and guest transport commands."""

import fcntl
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
        output = self.helper("review").stdout.decode()
        self.assertIn(f"Target: {wip}", output)
        self.assertIn("+guest unstaged", output)
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

    def import_files(self, files, message=b"Guest review fixture\n"):
        """Make exact guest tree bytes, bypassing attribute-driven conversions."""
        for path, (mode, content) in files.items():
            oid = content if mode == "160000" else self.git(
                self.guest, "hash-object", "-w", "--stdin", input=content,
            ).strip()
            self.git(self.guest, "update-index", "--add", "--cacheinfo", mode, oid, os.fsdecode(path))
        tree = self.git(self.guest, "write-tree").strip()
        # commit-tree repairs invalid UTF-8; write raw commit bytes to test the renderer.
        raw = (f"tree {tree}\nparent {self.ref('HEAD', self.guest)}\n"
               "author Transport test <transport@example.invalid> 0 +0000\n"
               "committer Transport test <transport@example.invalid> 0 +0000\n\n").encode() + message
        commit = self.git(self.guest, "hash-object", "-t", "commit", "-w", "--stdin", input=raw).strip()
        self.git(self.guest, "update-ref", "refs/heads/main", commit)
        self.git(self.guest, "update-ref", "refs/export/wip", commit)
        (self.instance() / "outbox/export.bundle").write_bytes(self.bundle("--branches", "refs/export/wip"))
        self.helper("import")
        return commit

    def test_review_hostile_attributes_paths_and_content(self):
        (self.host / "flake.nix").write_bytes(b"{ before = true; }\n")
        self.git(self.host, "add", "flake.nix")
        self.git(self.host, "commit", "-m", "Review base")
        base = self.ref("HEAD")
        self.init_guest()
        controls = (b"CSI \x1b[31mred\x1b[0m\nOSC \x1b]0;title\x07\n"
                    b"C0 \x01 DEL \x7f C1 \xc2\x85\nInvalid \xff\x80\n"
                    b"Literal \\x1b[31m actual \x1b[31m\n" +
                    "Bidi \u202a\u202b\u202c\u202d\u202e\u2066\u2067\u2068\u2069\n".encode())
        odd_path = b"odd\tline\n\x1b\xff" + "\u202e".encode() + b".txt"
        files = {
            b".gitattributes": ("100644", b"* diff=evil filter=evil\n* text eol=crlf\n*.nix -diff\n"),
            b"sub/.gitattributes": ("100644", b"*.nix -diff\n"),
            b"sub/.envrc": ("100644", b"use flake\n"),
            b"sub/flake.nix": ("100644", b"{ nestedFlake = true; }\n"),
            b"sub/flake.lock": ("100644", b"{}\n"),
            b"flake.nix": ("100644", b"{ after = true; }\r\n"),
            b"sub/module.nix": ("100644", b"{ nested = true; }\n"),
            b"controls.txt": ("100644", controls),
            odd_path: ("100644", b"odd path content\n++ preserved line\n"),
            b":(glob)*": ("100644", b"literal pathspec\n"),
            b".gitmodules": ("100644", b"# submodules\n"),
            b".envrc": ("100644", b"use flake\n"),
            b"flake.lock": ("100644", b"{}\n"),
            b".github/workflows/check.yml": ("100644", b"name: check\n"),
            b".pre-commit-config.yaml": ("100644", b"repos: []\n"),
            b"lefthook.yml": ("100644", b"pre-commit: {}\n"),
            b".husky/pre-commit": ("100644", b"exit 0\n"),
            b".vscode/settings.json": ("100644", b"{}\n"),
            b".idea/workspace.xml": ("100644", b"<project/>\n"),
            b"run.sh": ("100755", b"#!/bin/sh\nexit 0\n"),
            b"tracked": ("100755", b"initial\n"),
            b"link": ("120000", b"../target"),
            b"submodule": ("160000", base),
            b"large.dat": ("100644", b"version https://git-lfs.github.com/spec/v1\n"
                           b"oid sha256:" + b"a" * 64 + b"\nsize 42\n"),
            b"binary.dat": ("100644", b"\0\xffopaque\n"),
        }
        target = self.import_files(files, b"Guest controls \x1b]0;log\x07 \xff " + "\u202e\n".encode())
        marker = self.root / "driver-marker"
        driver = self.root / "evil-driver"
        driver.write_text(f"#!/bin/sh\nprintf ran > '{marker}'\nprintf converted\n")
        driver.chmod(0o755)
        self.run_command(str(driver))
        self.assertTrue(marker.exists())
        marker.unlink()
        for setting in ("diff.evil.textconv", "diff.evil.command", "filter.evil.clean", "filter.evil.smudge"):
            self.git(self.host, "config", setting, str(driver))
        (self.host / ".git/info/attributes").write_text("* -diff\n")
        hook_markers = self.marker_hooks()
        before = self.checkout_state(self.host)
        refs = self.refs()
        output = self.helper("review").stdout.decode("utf-8")
        self.assertIn(f"Host HEAD: {base}\nTarget: {target}\nMerge base: {base}", output)
        self.assertTrue(output.endswith(f"To merge exactly this reviewed commit: git merge {target}\n"))
        self.assertIn("+{ after = true; }\\x0d\n", output)
        self.assertIn("+{ nested = true; }", output)
        self.assertIn("+literal pathspec", output)
        self.assertIn("+++ preserved line", output)
        self.assertIn("Guest controls \\x1b]0;log\\x07 \\xff \\u{202e}", output)
        for expected in (r"\x1b[31m", r"\x1b]0;title\x07", r"\x01", r"\x7f", r"\u{0085}", r"\xff\x80"):
            self.assertIn(expected, output)
        self.assertIn(r"Literal \\x1b[31m actual \x1b[31m", output)
        for code in (*range(0x202A, 0x202F), *range(0x2066, 0x206A)):
            self.assertIn(f"\\u{{{code:04x}}}", output)
        for character in output:
            code = ord(character)
            self.assertFalse((code < 32 and character not in "\n\t") or 0x7F <= code <= 0x9F or
                             0x202A <= code <= 0x202E or 0x2066 <= code <= 0x2069)
        quoted = r'"odd\x09line\x0a\x1b\xff\u{202e}.txt"'
        summary = output.split("Changed paths (status, old mode -> new mode)\n", 1)[1].split("\nRuns on", 1)[0]
        self.assertIn(f"A 000000 -> 100644 {quoted}", summary)
        # Git quotes path bytes first; escaped() then doubles its backslashes.
        patch_path = r'odd\\tline\\n\\033\\377\\342\\200\\256.txt'
        self.assertIn(f'diff --git "a/{patch_path}" "b/{patch_path}"\n', output)
        self.assertIn(f'+++ "b/{patch_path}"\n', output)
        highlights = output.split("Runs on the host after merge\n", 1)[1].split("\nNot reviewed", 1)[0]
        for path in (".gitattributes", "sub/.gitattributes", ".gitmodules", ".envrc", "flake.nix", "flake.lock",
                     "sub/.envrc", "sub/flake.nix", "sub/flake.lock",
                     ".github/workflows/check.yml", ".pre-commit-config.yaml", "lefthook.yml", ".husky/pre-commit",
                     ".vscode/settings.json", ".idea/workspace.xml", "run.sh", "tracked", "link", "submodule", "large.dat"):
            self.assertIn(f'"{path}":', highlights)
        self.assertIn('"binary.dat": not reviewed', output)
        self.assertIn("+../target", output)
        self.assertIn(f"+Subproject commit {base}", output)
        self.assertFalse(marker.exists())
        for marker in hook_markers:
            self.assertFalse(marker.exists())
        self.assertEqual(before, self.checkout_state(self.host))
        self.assertEqual(refs, self.refs())

    def test_review_refs_and_unrelated_history(self):
        self.init_guest()
        self.export()
        self.helper("import")
        before = self.refs()
        checkout = self.checkout_state(self.host)
        for ref in ("refs/heads/main", "refs/remotes/vm-other/wip", "refs/remotes/vm-tester/wip"):
            result = self.helper("review", ref, success=False)
            self.assertIn(b"review ref must be inside refs/remotes/vm-test/", result.stderr)
        self.assertEqual(before, self.refs())
        tree = self.ref("HEAD^{tree}", self.guest)
        unrelated = self.git(self.guest, "commit-tree", tree, input=b"Unrelated root\n").strip()
        self.git(self.guest, "update-ref", "refs/export/wip", unrelated)
        (self.instance() / "outbox/export.bundle").write_bytes(self.bundle("--branches", "refs/export/wip"))
        self.helper("import")
        before = self.refs()
        result = self.helper("review", success=False)
        self.assertIn(b"unrelated histories (no merge base)", result.stderr)
        self.assertEqual(checkout, self.checkout_state(self.host))
        self.assertEqual(before, self.refs())

    def test_discard_lock_and_outbox_symlink(self):
        self.init_guest()
        self.export()
        self.helper("import")
        instance = self.instance()
        self.git(self.host, "update-ref", "refs/remotes/vm-other/wip", self.initial)
        self.git(self.host, "update-ref", "refs/remotes/vm-tester/wip", self.initial)
        markers = self.marker_hooks()
        outside = self.root / "outside"
        outside.mkdir()
        (outside / "survive").write_text("keep\n")
        (instance / "outbox/escape").symlink_to(outside, target_is_directory=True)
        before = self.refs()
        checkout = self.checkout_state(self.host)
        with (instance.parents[1] / "locks/test.lock").open("a+b") as held:
            fcntl.flock(held, fcntl.LOCK_EX | fcntl.LOCK_NB)
            result = self.helper("discard", "--refs", "--yes", success=False)
            self.assertIn(b"instance is running: test", result.stderr)
            self.assertTrue(instance.exists())
            self.assertEqual(before, self.refs())
        self.helper("discard", "--refs", "--yes")
        self.assertFalse(instance.exists())
        self.assertEqual((outside / "survive").read_text(), "keep\n")
        expected = b"".join(line + b"\n" for line in before.splitlines()
                            if not line.startswith(b"refs/remotes/vm-test/"))
        self.assertEqual(expected, self.refs())
        self.assertEqual(checkout, self.checkout_state(self.host))
        for marker in markers:
            self.assertFalse(marker.exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
