#!/usr/bin/env python3
"""Run a command while enforcing a hard timeout between stderr heartbeats."""

from __future__ import annotations

import argparse
import os
import selectors
import signal
import subprocess
import sys
import time
from pathlib import Path


TIMEOUT_EXIT_CODE = 124


class TerminationRequested(Exception):
    def __init__(self, signum: int) -> None:
        self.signum = signum


def stop_process_group(process: subprocess.Popen[bytes], grace_seconds: float) -> None:
    """Stop the command and every child it launched, escalating when needed."""
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    try:
        process.wait(timeout=grace_seconds)
    except subprocess.TimeoutExpired:
        pass
    # The leader may exit on SIGTERM while a descendant ignores it. Always
    # signal the original process group once more instead of assuming a reaped
    # leader means the entire automation tree stopped.
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except (ProcessLookupError, PermissionError):
        pass
    final_wait_seconds = max(grace_seconds, 1.0)
    try:
        process.wait(timeout=final_wait_seconds)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=final_wait_seconds)


def run(
    command: list[str],
    stdout_path: Path,
    inactivity_timeout_seconds: float,
    termination_grace_seconds: float,
) -> int:
    last_activity = time.monotonic()
    timed_out = False
    termination_signal: int | None = None
    with stdout_path.open("wb") as stdout:
        process = subprocess.Popen(
            command,
            stdin=subprocess.DEVNULL,
            stdout=stdout,
            stderr=subprocess.PIPE,
            start_new_session=True,
        )
        assert process.stderr is not None
        stderr_fd = process.stderr.fileno()
        os.set_blocking(stderr_fd, False)
        selector = selectors.DefaultSelector()
        selector.register(stderr_fd, selectors.EVENT_READ)
        stderr_open = True
        watched_signals = (signal.SIGINT, signal.SIGTERM)
        previous_signal_handlers = {
            watched_signal: signal.getsignal(watched_signal)
            for watched_signal in watched_signals
        }

        def request_termination(signum: int, _frame: object) -> None:
            raise TerminationRequested(signum)

        for watched_signal in watched_signals:
            signal.signal(watched_signal, request_termination)
        try:
            while process.poll() is None:
                remaining = inactivity_timeout_seconds - (
                    time.monotonic() - last_activity
                )
                if remaining <= 0:
                    timed_out = True
                    break
                if stderr_open:
                    events = selector.select(timeout=min(remaining, 0.1))
                else:
                    time.sleep(min(remaining, 0.1))
                    events = []
                for _key, _mask in events:
                    try:
                        chunk = os.read(stderr_fd, 65_536)
                    except BlockingIOError:
                        continue
                    if chunk:
                        sys.stderr.buffer.write(chunk)
                        sys.stderr.buffer.flush()
                        last_activity = time.monotonic()
                    else:
                        selector.unregister(stderr_fd)
                        process.stderr.close()
                        stderr_open = False

            if timed_out:
                print(
                    "Accessibility automation produced no progress for "
                    f"{inactivity_timeout_seconds:g}s; terminating its process group.",
                    file=sys.stderr,
                    flush=True,
                )
                stop_process_group(process, termination_grace_seconds)
        except TerminationRequested as request:
            termination_signal = request.signum
            stop_process_group(process, termination_grace_seconds)
        finally:
            if stderr_open:
                while True:
                    try:
                        chunk = os.read(stderr_fd, 65_536)
                    except BlockingIOError:
                        break
                    if not chunk:
                        break
                    sys.stderr.buffer.write(chunk)
            sys.stderr.buffer.flush()
            for watched_signal, previous_handler in previous_signal_handlers.items():
                signal.signal(watched_signal, previous_handler)
            selector.close()
            if stderr_open:
                process.stderr.close()

    if termination_signal is not None:
        return 128 + termination_signal
    return TIMEOUT_EXIT_CODE if timed_out else process.returncode


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--inactivity-timeout", type=float, required=True)
    parser.add_argument("--termination-grace", type=float, default=2.0)
    parser.add_argument("--stdout", type=Path, required=True)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command
    if command[:1] == ["--"]:
        command = command[1:]
    if not command:
        parser.error("a command is required after --")
    if args.inactivity_timeout <= 0:
        parser.error("--inactivity-timeout must be positive")
    if args.termination_grace < 0:
        parser.error("--termination-grace cannot be negative")
    return run(
        command,
        args.stdout,
        args.inactivity_timeout,
        args.termination_grace,
    )


if __name__ == "__main__":
    raise SystemExit(main())
