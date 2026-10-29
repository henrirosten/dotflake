"""Shared state paths and permanent instance locks for host tools."""

import contextlib
import fcntl
import os
from pathlib import Path


def state_root():
    state = Path(os.environ.get("XDG_STATE_HOME") or Path.home() / ".local/state")
    return state / "dotflake/agents"


def instance_lock_path(project_state, instance):
    return Path(project_state) / "locks" / f"{instance}.lock"


@contextlib.contextmanager
def instance_lock(project_state, instance):
    """Acquire without waiting; take the project lock first when acquiring both."""
    with instance_lock_path(project_state, instance).open("a+b") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        yield lock


def instance_running(project_state, instance):
    """Probe the permanent lock without deleting or replacing its inode."""
    try:
        with instance_lock(project_state, instance):
            return False
    except BlockingIOError:
        return True
