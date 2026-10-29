#!/usr/bin/env python3
"""Exchange full Git bundles with an agent, without changing the host checkout."""

import argparse
import contextlib
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile


GIT = "@git@"
RUNTIME_PATH = "@runtimePath@"
FETCH_OPTIONS = [
    "--no-tags", "--atomic", "--no-recurse-submodules",
    "--no-auto-maintenance", "--no-write-fetch-head",
]


class AgentError(Exception):
    pass


def git_environment(home):
    """The single environment used by every host-side Git invocation."""
    env = {key: value for key, value in os.environ.items()
           if not key.startswith("GIT_")}
    env.update(
        PATH=RUNTIME_PATH,
        HOME=str(home),
        GIT_CONFIG_NOSYSTEM="1",
        GIT_CONFIG_GLOBAL="/dev/null",
        GIT_ATTR_NOSYSTEM="1",
    )
    return env


class Git:
    def __init__(self, home):
        self.env = git_environment(home)

    def run(self, cwd, *args, check=True):
        result = subprocess.run(
            [GIT, "--no-pager", "--no-optional-locks",
             "-c", "core.hooksPath=/dev/null",
             "-c", "hook.reference-transaction.enabled=false",
             "-c", "hook.post-index-change.enabled=false",
             "-c", "core.fsmonitor=false",
             "-c", "core.attributesFile=/dev/null",
             "-c", "fetch.fsckObjects=true", *args],
            cwd=cwd, env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        if check and result.returncode:
            raise AgentError(result.stderr.decode(errors="replace").strip()
                             or f"git {args[0]} failed")
        return result

    def text(self, cwd, *args):
        return os.fsdecode(self.run(cwd, *args).stdout).rstrip("\n")


class Project:
    def __init__(self, git, path, instance):
        self.git = git
        path = Path(path).resolve()
        if not path.is_dir() or git.run(path, "rev-parse", "--git-dir", check=False).returncode:
            raise AgentError(f"{path} is not in a Git repository; start from one or pass --project PATH")
        bare = git.text(path, "rev-parse", "--is-bare-repository") == "true"
        self.path = path if bare else Path(git.text(path, "rev-parse", "--show-toplevel"))
        self.common = Path(git.text(
            self.path, "rev-parse", "--path-format=absolute", "--git-common-dir",
        )).resolve()
        if git.text(self.path, "rev-parse", "--is-shallow-repository") == "true":
            raise AgentError("shallow repositories are not supported")
        partial = git.run(self.path, "config", "--get-regexp",
                          r"^(extensions\.partialclone|remote\..*\.promisor)$", check=False)
        if partial.returncode not in (0, 1):
            raise AgentError("cannot read partial-clone configuration")
        for line in os.fsdecode(partial.stdout).splitlines():
            key, _, value = line.partition(" ")
            if key == "extensions.partialclone" or value.lower() not in ("false", "no", "off", "0"):
                raise AgentError("partial clones are not supported")
        sparse = git.run(self.path, "config", "--bool", "--get", "core.sparseCheckout", check=False)
        if sparse.returncode not in (0, 1):
            raise AgentError("cannot read sparse-checkout configuration")
        if sparse.stdout.strip() == b"true":
            raise AgentError("sparse checkouts are not supported")
        head = git.run(self.path, "rev-parse", "--verify", "HEAD^{commit}", check=False)
        if head.returncode:
            raise AgentError("unborn HEAD is not supported; commit before exchanging work")
        if git.text(self.path, "rev-parse", "--show-object-format") != "sha1":
            raise AgentError("only SHA-1 repositories are supported")
        # The main repository, shared by all worktrees; bare repositories have no .git.
        self.repo = self.common.parent if self.common.name == ".git" else self.common
        # QEMU reads commas in paths as option separators; the hash keeps IDs unique.
        basename = re.sub(r"[^A-Za-z0-9._-]", "_", self.repo.name.removesuffix(".git"))
        short_hash = hashlib.sha256(os.fsencode(self.common)).hexdigest()[:12]
        state = Path(os.environ.get("XDG_STATE_HOME") or Path.home() / ".local/state")
        root = state / "dotflake/agents"
        self.state = root / f"{basename}-{short_hash}"
        self.instance = instance
        self.inbox = self.state / "instances" / instance / "inbox"
        self.outbox = self.state / "instances" / instance / "outbox"
        for directory in (root.parent, root, self.state, self.state / "locks",
                          self.state / "instances", self.inbox.parent, self.inbox, self.outbox):
            directory.mkdir(mode=0o700, parents=True, exist_ok=True)
            if directory.is_symlink():
                raise AgentError(f"state directory is a symlink: {directory}")
            directory.chmod(0o700)

    @contextlib.contextmanager
    def locked(self):
        with (self.state / "locks/project.lock").open("a+b") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            # Record the main repository, independent of the invoking worktree.
            (self.state / "project-path").write_text(str(self.repo) + "\n")
            yield

    def refs(self):
        output = self.git.text(self.path, "for-each-ref", "--format=%(refname) %(objectname)")
        return dict(line.split(" ", 1) for line in output.split("\n")) if output else {}


def push(project, branches):
    git = project.git
    with project.locked():
        head_ref = git.run(project.path, "symbolic-ref", "--quiet", "HEAD", check=False)
        if not branches:
            if head_ref.returncode:
                raise AgentError("detached HEAD requires --branch")
            branches = [os.fsdecode(head_ref.stdout).rstrip("\n").removeprefix("refs/heads/")]
        refs = []
        for branch in dict.fromkeys(branches):
            ref = f"refs/heads/{branch}"
            if git.run(project.path, "check-ref-format", ref, check=False).returncode:
                raise AgentError(f"invalid branch name: {branch!r}")
            git.run(project.path, "rev-parse", "--verify", f"{ref}^{{commit}}")
            refs.append(ref)
        temporary = project.inbox / ".host.tmp"
        try:
            git.run(project.path, "bundle", "create", "--version=2", str(temporary), *refs)
            commit = git.text(project.path, "bundle", "list-heads", str(temporary), refs[0]).split(" ", 1)[0]
            os.replace(temporary, project.inbox / "host.bundle")
            temporary.write_text(json.dumps({"branch": branches[0], "commit": commit}) + "\n")
            os.replace(temporary, project.inbox / "host.json")
        finally:
            temporary.unlink(missing_ok=True)
        print(f"Pushed {commit} ({', '.join(branches)}) to {project.inbox}")


def copy_export(project, destination, max_bytes):
    directory = os.open(project.outbox, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        source = os.open("export.bundle", os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK,
                         dir_fd=directory)
    finally:
        os.close(directory)
    digest = hashlib.sha256()
    with os.fdopen(source, "rb", buffering=0) as source_file, destination.open("wb") as target:
        before = os.fstat(source_file.fileno())
        if not stat.S_ISREG(before.st_mode):
            raise AgentError("export.bundle must be a regular file")
        if before.st_size > max_bytes:
            raise AgentError(f"export.bundle exceeds the {max_bytes}-byte size limit")
        copied = 0
        while copied < max_bytes:
            chunk = source_file.read(min(1024 * 1024, max_bytes - copied))
            if not chunk:
                break
            target.write(chunk)
            digest.update(chunk)
            copied += len(chunk)
        after = os.fstat(source_file.fileno())
        def fingerprint(info):
            return (info.st_dev, info.st_ino, info.st_mode, info.st_size,
                    info.st_mtime_ns, info.st_ctime_ns)
        if fingerprint(before) != fingerprint(after) or copied != before.st_size:
            raise AgentError("export.bundle changed while being copied; export and retry")
    return digest.hexdigest()


def bundle_refs(project, bundle):
    """Read only the bounded header; Git validates the pack in private staging."""
    refs = {}
    # Bound both individual reads and total header data, independently of pack size.
    budget = 1024 * 1024
    with bundle.open("rb") as source:
        def line():
            nonlocal budget
            data = source.readline(min(budget, 65536) + 1)
            budget -= len(data)
            if budget < 0 or len(data) > 65536:
                raise AgentError("bundle header is too large")
            if not data.endswith(b"\n"):
                raise AgentError("truncated bundle header")
            return data[:-1]
        signature = line()
        if signature != b"# v2 git bundle":
            raise AgentError("only v2 Git bundles are supported")
        while True:
            entry = line()
            if not entry:
                break
            if entry.startswith(b"-"):
                raise AgentError("bundle prerequisites are not allowed")
            if entry.startswith(b"@"):
                raise AgentError("bundle capabilities are not supported (v2 only)")
            oid, separator, name = entry.partition(b" ")
            ref = os.fsdecode(name)
            if not separator or not re.fullmatch(rb"[0-9a-fA-F]{40}", oid):
                raise AgentError("invalid bundle ref entry")
            if not (ref.startswith("refs/heads/") or ref == "refs/export/wip"):
                raise AgentError(f"bundle ref outside the wire contract: {ref!r}")
            if "\0" in ref or project.git.run(project.path, "check-ref-format", ref, check=False).returncode:
                raise AgentError(f"invalid bundle ref name: {ref!r}")
            if ref in refs:
                raise AgentError(f"duplicate bundle ref: {ref!r}")
            refs[ref] = oid.decode().lower()
    if not refs:
        raise AgentError("bundle has no refs")
    listed = project.git.text(project.path, "bundle", "list-heads", str(bundle))
    if dict(line.split(" ", 1)[::-1] for line in listed.split("\n")) != refs:
        raise AgentError("bundle header disagrees with git bundle list-heads")
    return refs


def import_bundle(project, max_bytes):
    git = project.git
    with project.locked(), tempfile.TemporaryDirectory(prefix="dotflake-import-") as temporary:
        temporary = Path(temporary)
        bundle = temporary / "export.bundle"
        digest = copy_export(project, bundle, max_bytes)
        refs = bundle_refs(project, bundle)
        staging = temporary / "staging.git"
        git.run(temporary, "init", "--bare", "--template=", str(staging))
        # A single staging prefix gives promotion one refspec and one prune domain.
        suffixes = {ref: "heads/" + ref.removeprefix("refs/heads/")
                    if ref.startswith("refs/heads/") else "wip" for ref in refs}
        git.run(staging, "fetch", *FETCH_OPTIONS, str(bundle),
                *[f"+{ref}:refs/transport/{suffixes[ref]}" for ref in refs])
        for ref, oid in refs.items():
            if git.text(staging, "cat-file", "-t", oid) != "commit":
                raise AgentError(f"bundle ref does not point to a commit: {ref!r}")
        prefix = f"refs/remotes/vm-{project.instance}/"
        existing = project.refs()
        old = {ref: oid for ref, oid in existing.items() if ref.startswith(prefix)}
        new = {prefix + suffixes[ref]: oid for ref, oid in refs.items()}
        final = set(existing).difference(old).union(new)
        for ref in new:
            parts = ref.split("/")
            if any("/".join(parts[:length]) in final for length in range(1, len(parts))):
                raise AgentError(f"destination ref collision: {ref!r}")
            if any(other.startswith(ref + "/") for other in final):
                raise AgentError(f"destination ref collision: {ref!r}")
        git.run(project.path, "fetch", *FETCH_OPTIONS, "--prune", str(staging),
                f"+refs/transport/*:{prefix}*")
        print(f"SHA-256 {digest}")
        for ref in sorted(old.keys() | new.keys()):
            print(f"{ref} {old.get(ref, '-')} -> {new.get(ref, '-')}")


def instance_name(value):
    if not re.fullmatch(r"[a-z][a-z0-9-]{0,31}", value):
        raise argparse.ArgumentTypeError("instance must match [a-z][a-z0-9-]{0,31}")
    return value


def positive_integer(value):
    try:
        number = int(value)
    except ValueError:
        number = 0
    if number <= 0:
        raise argparse.ArgumentTypeError("must be a positive integer")
    return number


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    subcommands = parser.add_subparsers(dest="command", required=True)
    push_parser = subcommands.add_parser("push", help="send selected branches")
    push_parser.add_argument("--branch", action="append", help="branch to send (repeatable; default: current branch)")
    import_parser = subcommands.add_parser("import", help="validate and import an agent export")
    import_parser.add_argument("--max-bytes", type=positive_integer, default=512 * 1024 * 1024,
                               help="maximum bundle bytes (default: 536870912)")
    for name, subparser in subcommands.choices.items():
        if name != "list":
            subparser.add_argument("--project", default=".", help="repository path (default: current repository)")
            subparser.add_argument("--instance", type=instance_name, default="default", help="agent instance name (default: default)")
    args = parser.parse_args()
    os.umask(0o077)
    try:
        with tempfile.TemporaryDirectory(prefix="dotflake-agent-home-") as home:
            project = Project(Git(home), args.project, args.instance)
            if args.command == "push":
                push(project, args.branch)
            else:
                import_bundle(project, args.max_bytes)
    except (AgentError, OSError) as error:
        print(f"dotflake-agent: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
