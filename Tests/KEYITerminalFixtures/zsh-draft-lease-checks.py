#!/usr/bin/env python3
"""Isolated PTY regression checks for the opt-in KEYI ZLE draft bridge."""

import json
import os
import pty
import select
import shutil
import subprocess
import sys
import tempfile
import time
import uuid
from pathlib import Path


REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "Scripts/Terminal/keyi-zsh-draft.zsh"
HELPER = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else REPO / ".build/debug/KEYITerminal"
if not HELPER.is_file():
    raise SystemExit(f"KEYITerminal not found: {HELPER}; build it or pass the binary path")


def check(condition, message):
    if not condition:
        raise AssertionError(message)


def drain(fd, duration=0.2):
    end = time.monotonic() + duration
    chunks = []
    while time.monotonic() < end:
        ready, _, _ = select.select([fd], [], [], max(0, end - time.monotonic()))
        if ready:
            try:
                chunks.append(os.read(fd, 65536))
            except OSError:
                break
    return b"".join(chunks)


class ZshPTY:
    def __init__(self, fixture_root):
        self.fixture_root = Path(fixture_root)
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            env = dict(os.environ)
            env.update(
                ZDOTDIR=str(self.fixture_root),
                TERM_PROGRAM="Apple_Terminal",
                TERM="xterm-256color",
                KEYI_TERMINAL_HELPER=str(self.fixture_root / "helper.sh"),
            )
            os.execve("/bin/zsh", ["zsh", "-dfi"], env)
        drain(self.fd)
        source = f"unset HISTFILE; PS1='LEASE> '; source '{SCRIPT}'\n"
        os.write(self.fd, source.encode())
        drain(self.fd, 1.5)

    def type_text(self, text):
        os.write(self.fd, text.encode())
        return drain(self.fd, 0.2)

    def run_helper(self, args, input_data=None, timeout=6):
        process = subprocess.Popen(
            args,
            stdin=subprocess.PIPE if input_data is not None else subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        if input_data is not None:
            process.stdin.write(input_data)
            process.stdin.close()
            process.stdin = None

        deadline = time.monotonic() + timeout
        while process.poll() is None:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                process.kill()
                process.communicate()
                raise subprocess.TimeoutExpired(args, timeout)
            try:
                ready, _, _ = select.select([self.fd], [], [], min(0.05, remaining))
                if ready:
                    os.read(self.fd, 65536)
            except OSError:
                pass

        stdout, stderr = process.communicate()
        return subprocess.CompletedProcess(args, process.returncode, stdout, stderr)

    def capture(self):
        args = [str(HELPER), "zsh-draft", "capture", str(os.getpid())]
        result = self.run_helper(args)
        check(result.returncode == 0, f"capture failed: {result.stderr.decode(errors='replace')}")
        return json.loads(result.stdout)

    def close(self):
        try:
            os.write(self.fd, b"\x03")
            drain(self.fd, 0.2)
            os.write(self.fd, b"exit\n")
            drain(self.fd, 0.2)
        except OSError:
            pass
        os.close(self.fd)
        try:
            os.waitpid(self.pid, 0)
        except ChildProcessError:
            pass


def write_lease(capture, ttl_us=2_500_000):
    lease_id = str(uuid.uuid4())
    deadline = time.time_ns() // 1000 + ttl_us
    session_dir = Path(f"/private/tmp/keyi-zsh-draft-{os.getuid()}") / capture["sessionID"]
    lease_path = session_dir / f"lease-{lease_id}.txt"
    fd = os.open(lease_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        os.write(fd, f"{lease_id}\t{deadline}\t1\n".encode())
    finally:
        os.close(fd)
    return lease_id, deadline, lease_path, session_dir / f"reply-{lease_id}.fifo"


def commit_process(shell, capture, lease, text):
    lease_id, deadline, _, _ = lease
    request = dict(
        capture,
        translatedText=text,
        leaseID=lease_id,
        leaseDeadlineUnixMicroseconds=deadline,
    )
    return shell.run_helper(
        [str(HELPER), "zsh-draft", "commit"],
        input_data=json.dumps(request).encode(),
    )


def start_commit(capture, lease, text):
    lease_id, deadline, _, _ = lease
    request = dict(
        capture,
        translatedText=text,
        leaseID=lease_id,
        leaseDeadlineUnixMicroseconds=deadline,
    )
    process = subprocess.Popen(
        [str(HELPER), "zsh-draft", "commit"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    process.stdin.write(json.dumps(request).encode())
    process.stdin.close()
    return process


def close_shell(shell, lease=None):
    if lease is not None:
        lease[2].unlink(missing_ok=True)
        lease[3].unlink(missing_ok=True)
    shell.close()


def make_fixture():
    root = Path(tempfile.mkdtemp(prefix="keyi-zsh-lease-", dir="/private/tmp"))
    root.chmod(0o700)
    (root / "delay").mkdir(mode=0o700)
    shim = root / "helper.sh"
    shim.write_text(
        "#!/bin/sh\n"
        'if [ "$1" = zsh-draft ] && [ "$2" = probe ] && [ -f "$KEYI_FIXTURE_ROOT/delay/seconds" ]; then\n'
        '  : > "$KEYI_FIXTURE_ROOT/probe-started"\n'
        '  IFS= read -r delay < "$KEYI_FIXTURE_ROOT/delay/seconds"\n'
        '  /bin/sleep "$delay"\n'
        "fi\n"
        'exec "$KEYI_FIXTURE_BINARY" "$@"\n',
        encoding="utf-8",
    )
    shim.chmod(0o700)
    return root


def set_delay(root, seconds):
    path = root / "delay/seconds"
    if seconds is None:
        path.unlink(missing_ok=True)
    else:
        path.write_text(f"{seconds}\n", encoding="ascii")


def wait_for_probe(root, process, timeout=2.0):
    marker = root / "probe-started"
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if marker.exists():
            return
        if process.poll() is not None:
            raise AssertionError("commit helper exited before the delayed probe started")
        time.sleep(0.02)
    raise AssertionError("zsh did not enter the delayed probe")


def fixture_env(root):
    env = dict(os.environ)
    env["KEYI_FIXTURE_ROOT"] = str(root)
    env["KEYI_FIXTURE_BINARY"] = str(HELPER)
    return env


def run_positive(root):
    shell = ZshPTY(root)
    lease = None
    try:
        shell.type_text("正常确认草稿🙂")
        capture = shell.capture()
        check(capture["buffer"] == "正常确认草稿🙂", "capture must return the typed ZLE buffer")
        lease = write_lease(capture)
        result = commit_process(shell, capture, lease, "translated fixture")
        check(result.returncode == 0, f"commit failed: {result.stderr.decode(errors='replace')}")
        check(json.loads(result.stdout)["committed"], "live lease must accept the commit")
        check(shell.capture()["buffer"] == "translated fixture", "accepted commit must replace the buffer")
    finally:
        close_shell(shell, lease)


def run_late_probe(root):
    shell = ZshPTY(root)
    lease = None
    try:
        shell.type_text("late probe original")
        capture = shell.capture()
        lease = write_lease(capture)
        set_delay(root, "3.2")
        started = time.monotonic()
        result = commit_process(shell, capture, lease, "late translation")
        elapsed = time.monotonic() - started
        set_delay(root, None)
        drain(shell.fd, 1.0)
        check(result.returncode != 0 and elapsed < 3.1, "helper must time out before the delayed probe returns")
        check(shell.capture()["buffer"] == capture["buffer"], "expired lease must not write a late translation")
    finally:
        close_shell(shell, lease)


def run_dead_reader(root):
    shell = ZshPTY(root)
    lease = None
    try:
        shell.type_text("dead reader original")
        capture = shell.capture()
        lease = write_lease(capture)
        set_delay(root, "3.2")
        (root / "probe-started").unlink(missing_ok=True)
        process = start_commit(capture, lease, "reader vanished")
        wait_for_probe(root, process)
        process.kill()
        process.wait(timeout=2)
        drain(shell.fd, 3.0)
        set_delay(root, None)
        start = time.monotonic()
        check(shell.capture()["buffer"] == capture["buffer"], "dead ACK reader must not commit")
        check(time.monotonic() - start < 1.0, "ZLE must remain responsive after its ACK reader dies")
        redraw = shell.type_text("x")
        check(b"x" in redraw, "shell must accept and redraw a character after dead reader")
    finally:
        close_shell(shell, lease)


def run_expired_lease(root):
    shell = ZshPTY(root)
    lease = None
    try:
        shell.type_text("expired lease original")
        capture = shell.capture()
        lease = write_lease(capture, ttl_us=600_000)
        set_delay(root, "1.0")
        (root / "probe-started").unlink(missing_ok=True)
        result = commit_process(shell, capture, lease, "expired translation")
        set_delay(root, None)
        check(result.returncode != 0, "expired lease must be rejected while the ACK reader is still open")
        check(shell.capture()["buffer"] == capture["buffer"], "expired lease must preserve the original buffer")
    finally:
        close_shell(shell, lease)


def run_revoked_lease(root):
    shell = ZshPTY(root)
    lease = None
    try:
        shell.type_text("revoked lease original")
        capture = shell.capture()
        lease = write_lease(capture)
        set_delay(root, "1.0")
        (root / "probe-started").unlink(missing_ok=True)
        process = start_commit(capture, lease, "revoked translation")
        wait_for_probe(root, process)
        lease[2].unlink(missing_ok=True)
        # Keep the reader alive: this reaches the post-probe active-lease check.
        process.wait(timeout=4)
        set_delay(root, None)
        check(process.returncode != 0, "revoked lease must reject a still-connected commit helper")
        check(shell.capture()["buffer"] == capture["buffer"], "revoked lease must preserve the original buffer")
    finally:
        close_shell(shell, lease)


def run_edit_restore(root):
    shell = ZshPTY(root)
    lease = None
    try:
        shell.type_text("edit restore original")
        capture = shell.capture()
        shell.type_text("x\x7f")
        lease = write_lease(capture)
        result = commit_process(shell, capture, lease, "stale translation")
        check(result.returncode != 0, "edit-restore must invalidate the captured ticket")
        check(shell.capture()["buffer"] == capture["buffer"], "edit-restore must preserve the restored draft")
    finally:
        close_shell(shell, lease)


def main():
    root = make_fixture()
    os.environ.update(fixture_env(root))
    try:
        run_positive(root)
        run_late_probe(root)
        run_dead_reader(root)
        run_expired_lease(root)
        run_revoked_lease(root)
        run_edit_restore(root)
        print("KEYI ZLE lease PTY checks passed: positive, late, dead-reader, expired, revoked, edit-restore")
    finally:
        shutil.rmtree(root, ignore_errors=True)


if __name__ == "__main__":
    main()
