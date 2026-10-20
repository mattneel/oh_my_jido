"""Private-editor Linux child-subreaper; never imports or evaluates candidate code."""

import argparse
import ctypes
import errno
import json
import os
import signal
import stat
import sys
import time
import uuid


MAX_STATUS_BYTES = 524_288
MAX_IDENTITIES = 1_024
MAX_DIRECT_CHILDREN = 4_096
MAX_SCOPE_TASKS = 4_096
CHILDREN_BYTES = 65_536
SIGNAL_BUDGET_SECONDS = 0.1
SCOPE_BUDGET_SECONDS = 0.1
TERM_GRACE_SECONDS = 0.25
UNCERTAIN_AFTER_SECONDS = 2.5


def identity(pid, boot_id):
    try:
        with open(f"/proc/{pid}/stat", "rb") as source:
            value = source.read(4_097)
        if len(value) > 4_096:
            return None
        fields = value[value.rfind(b")") + 2 :].split()
        if len(fields) < 22:
            return None
        return {
            "pid": pid,
            "parent_pid": int(fields[1]),
            "process_group": int(fields[2]),
            "session": int(fields[3]),
            "start_time": fields[19].decode("ascii"),
            "boot_id": boot_id,
        }
    except (OSError, ValueError, UnicodeError):
        return None


def stamp(process):
    return process["pid"], process["start_time"], process["boot_id"]


def exit_status(wait_status):
    if os.WIFEXITED(wait_status):
        return os.WEXITSTATUS(wait_status)
    if os.WIFSIGNALED(wait_status):
        return 128 + os.WTERMSIG(wait_status)
    return None


class Keeper:
    def __init__(self, arguments):
        if sys.platform != "linux" or not hasattr(os, "fork"):
            raise OSError(errno.ENOSYS, "Linux child ownership unavailable")
        if not hasattr(os, "pidfd_open") or not hasattr(signal, "pidfd_send_signal"):
            raise OSError(errno.ENOSYS, "Linux identity-bound signals unavailable")

        self.arguments = arguments
        self.pid = os.getpid()
        with open("/proc/sys/kernel/random/boot_id", "r", encoding="ascii") as source:
            self.boot_id = source.read(129).strip()
        uuid.UUID(self.boot_id)
        self.keeper_identity = identity(self.pid, self.boot_id)
        if self.keeper_identity is None:
            raise OSError(errno.ENOTSUP, "Keeper identity unavailable")
        if os.getsid(0) != self.pid or os.getpgrp() != self.pid:
            raise OSError(errno.ENOTSUP, "Keeper requires its own session")

        self.directory = os.open(
            os.path.dirname(arguments.status), os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
        )
        directory_stat = os.fstat(self.directory)
        if directory_stat.st_uid != os.getuid() or stat.S_IMODE(directory_stat.st_mode) != 0o700:
            raise OSError(errno.EPERM, "Private status directory required")
        self.filename = os.path.basename(arguments.status)
        self.main_pid = None
        self.main_identity = None
        self.main_exit_status = None
        self.main_started = False
        self.spawn_attempted = False
        self.timed_out = False
        self.cancelled = False
        self.stop_started = None
        self.deadline = time.monotonic() + arguments.timeout_ms / 1_000
        self.owned = {stamp(self.keeper_identity): self.keeper_identity}
        self.live = dict(self.owned)
        self.owned_processes_complete = True
        self.scope_observed = False
        self.scope_error = None
        self.term_sent = set()
        self.kill_sent = set()
        self.last_write = 0.0
        self.last_status = None

        libc = ctypes.CDLL(None, use_errno=True)
        libc.prctl.restype = ctypes.c_int
        if libc.prctl(36, ctypes.c_ulong(1), 0, 0, 0) != 0:
            raise OSError(ctypes.get_errno(), "Child-subreaper ownership unavailable")
        enabled = ctypes.c_int(0)
        if libc.prctl(37, ctypes.byref(enabled), 0, 0, 0) != 0 or enabled.value != 1:
            raise OSError(errno.ENOTSUP, "Child-subreaper ownership unconfirmed")

        signal.signal(signal.SIGCHLD, signal.SIG_DFL)
        signal.signal(signal.SIGTERM, self.request_stop)
        signal.signal(signal.SIGINT, self.request_stop)
        descriptor = os.pidfd_open(self.pid, 0)
        try:
            signal.pidfd_send_signal(descriptor, 0)
        finally:
            os.close(descriptor)
        if self.children() or self.scope_error:
            raise OSError(errno.ENOTSUP, "Initial child ownership unavailable")
        self.persist("running", "process_starting", False, [])

    def request_stop(self, _number, _frame):
        self.cancelled = True

    def incomplete(self, reason):
        self.owned_processes_complete = False
        self.scope_error = self.scope_error or reason
        if self.stop_started is None:
            self.stop_started = time.monotonic()

    def observe(self, process):
        key = stamp(process)
        if key in self.owned or len(self.owned) < MAX_IDENTITIES:
            self.owned[key] = process
        else:
            self.incomplete("owned_process_inventory_limit")

    def children(self):
        try:
            with open(f"/proc/self/task/{self.pid}/children", "rb") as source:
                contents = source.read(CHILDREN_BYTES + 1)
            if len(contents) > CHILDREN_BYTES:
                self.incomplete("direct_children_inventory_limit")
                contents = contents[:CHILDREN_BYTES].rsplit(b" ", 1)[0]
            children = [int(value) for value in contents.split()]
            if len(children) > MAX_DIRECT_CHILDREN:
                self.incomplete("direct_children_count_limit")
            self.scope_observed = True
            return children[:MAX_DIRECT_CHILDREN]
        except (OSError, ValueError):
            self.incomplete("direct_children_unavailable")
            return []

    def descendant_identity(self, pid):
        process = identity(pid, self.boot_id)
        if process is None:
            try:
                os.stat(f"/proc/{pid}")
            except (FileNotFoundError, ProcessLookupError):
                pass
            except OSError:
                self.incomplete("descendant_identity_unavailable")
            else:
                self.incomplete("descendant_identity_unavailable")
        return process

    def observe_descendants(self, children):
        deadline = time.monotonic() + SCOPE_BUDGET_SECONDS
        pending = [(pid, self.keeper_identity) for pid in children]
        visited = set()
        live = {stamp(self.keeper_identity): self.keeper_identity}
        tasks = 0
        while pending:
            if time.monotonic() >= deadline:
                self.incomplete("descendant_scan_deadline")
                return
            pid, parent = pending.pop()
            process = self.descendant_identity(pid)
            if process is None or stamp(process) in visited:
                continue
            if process["parent_pid"] != parent["pid"]:
                continue
            current_parent = self.descendant_identity(parent["pid"])
            current = self.descendant_identity(pid)
            if (
                current_parent is None
                or stamp(current_parent) != stamp(parent)
                or current is None
                or stamp(current) != stamp(process)
                or current["parent_pid"] != parent["pid"]
            ):
                continue
            key = stamp(current)
            visited.add(key)
            self.observe(current)
            if key in self.owned:
                live[key] = current
            if len(visited) >= MAX_IDENTITIES:
                self.incomplete("owned_process_inventory_limit")
                return
            try:
                with os.scandir(f"/proc/{pid}/task") as entries:
                    for task in entries:
                        tasks += 1
                        if tasks > MAX_SCOPE_TASKS or time.monotonic() >= deadline:
                            self.incomplete("descendant_task_scan_bound")
                            return
                        try:
                            with open(f"/proc/{pid}/task/{task.name}/children", "rb") as source:
                                contents = source.read(CHILDREN_BYTES + 1)
                        except (FileNotFoundError, ProcessLookupError):
                            continue
                        if len(contents) > CHILDREN_BYTES:
                            self.incomplete("descendant_children_inventory_limit")
                            return
                        direct = [int(value) for value in contents.split()]
                        if (
                            len(direct) > MAX_DIRECT_CHILDREN
                            or len(pending) + len(direct) > MAX_DIRECT_CHILDREN
                        ):
                            self.incomplete("descendant_children_count_limit")
                            return
                        pending.extend((child, current) for child in direct)
            except (FileNotFoundError, ProcessLookupError):
                continue
            except (OSError, ValueError):
                self.incomplete("descendant_children_unavailable")
                return
        if self.owned_processes_complete:
            self.live = live

    def reap(self):
        while True:
            try:
                pid, status = os.waitpid(-1, os.WNOHANG)
            except ChildProcessError:
                return True
            except InterruptedError:
                continue
            if pid == 0:
                return False
            if pid == self.main_pid:
                self.main_exit_status = exit_status(status)

    def send_signal(self, pid, number):
        process = identity(pid, self.boot_id)
        if process is None or process["parent_pid"] != self.pid:
            return
        self.observe(process)
        key = stamp(process)
        sent = self.term_sent if number == signal.SIGTERM else self.kill_sent
        if key in sent:
            return

        descriptor = None
        try:
            descriptor = os.pidfd_open(pid, 0)
            current = identity(pid, self.boot_id)
            if current is None or stamp(current) != key or current["parent_pid"] != self.pid:
                self.incomplete("child_identity_changed")
                return
            signal.pidfd_send_signal(descriptor, number)
            sent.add(key)
        except ProcessLookupError:
            pass
        except OSError:
            self.incomplete("child_signal_unavailable")
        finally:
            if descriptor is not None:
                os.close(descriptor)

    def signal_children(self, children, now):
        deadline = time.monotonic() + SIGNAL_BUDGET_SECONDS
        number = (
            signal.SIGKILL
            if now - self.stop_started >= TERM_GRACE_SECONDS
            else signal.SIGTERM
        )
        for pid in children:
            if time.monotonic() >= deadline:
                self.incomplete("child_signal_scan_deadline")
                break
            self.send_signal(pid, number)

    def acknowledged(self):
        try:
            descriptor = os.open(
                self.filename + ".ack", os.O_RDONLY | os.O_NOFOLLOW, dir_fd=self.directory
            )
        except FileNotFoundError:
            return False
        with os.fdopen(descriptor, "rb") as source:
            metadata = os.fstat(source.fileno())
            if (
                not stat.S_ISREG(metadata.st_mode)
                or metadata.st_uid != os.getuid()
                or stat.S_IMODE(metadata.st_mode) != 0o600
                or metadata.st_size > 4_096
            ):
                raise OSError(errno.EPROTO, "Invalid keeper dispatch acknowledgement")
            contents = source.read(4_097)
        if len(contents) > 4_096:
            raise OSError(errno.EFBIG, "Keeper dispatch acknowledgement exceeds its bound")
        value = json.loads(contents)
        if not isinstance(value, dict) or type(value.get("schema")) is not int:
            raise OSError(errno.EPROTO, "Invalid keeper dispatch acknowledgement schema")
        if value != {
            "schema": 1,
            "launch_id": self.arguments.launch_id,
            "keeper_identity": self.keeper_identity,
        }:
            raise OSError(errno.EPROTO, "Keeper dispatch acknowledgement identity mismatch")
        os.fsync(self.directory)
        return True

    def await_acknowledgement(self):
        while True:
            now = time.monotonic()
            self.timed_out = now >= self.deadline
            if self.cancelled or self.timed_out:
                reason = "cancelled_before_target" if self.cancelled else "deadline_before_target"
                self.persist("settled", reason, False, [], not_started=True)
                return False
            try:
                if self.acknowledged() and not self.cancelled and time.monotonic() < self.deadline:
                    return True
            except (OSError, ValueError):
                self.persist(
                    "settled", "invalid_dispatch_acknowledgement", False, [], not_started=True
                )
                return False
            if now - self.last_write >= 0.1:
                self.persist("running", "awaiting_dispatch", False, [])
            time.sleep(0.02)

    def spawn(self):
        self.spawn_attempted = True
        pid = os.fork()
        if pid == 0:
            try:
                for number in (signal.SIGTERM, signal.SIGINT, signal.SIGPIPE, signal.SIGCHLD):
                    signal.signal(number, signal.SIG_DFL)
                os.setsid()
                descriptor = os.open(os.devnull, os.O_RDONLY)
                os.dup2(descriptor, 0)
                if descriptor != 0:
                    os.close(descriptor)
                os.execve(self.arguments.command[0], self.arguments.command, os.environ)
            except BaseException:
                try:
                    os.write(2, b"Candidate child executable could not start.\n")
                finally:
                    os._exit(127)

        self.main_pid = pid
        self.main_started = True
        self.main_identity = identity(pid, self.boot_id)
        if self.main_identity is not None:
            self.observe(self.main_identity)
        else:
            self.incomplete("main_identity_unavailable")
        self.persist("running", None, False, self.children())

    def persist(self, status, reason, all_children_reaped, children, not_started=False):
        owned = sorted(self.owned.values(), key=stamp)
        cleanup_status = (
            "not_started" if not_started else "confirmed" if all_children_reaped else "uncertain"
        )
        cleanup = {
            "status": cleanup_status,
            "authority": "linux_child_subreaper_waitpid",
            "subreaper": True,
            "all_children_reaped": all_children_reaped,
            "term": "sent" if self.term_sent else "not_needed",
            "kill": "sent" if self.kill_sent else "not_needed",
            "remaining": children[:MAX_IDENTITIES],
            "remaining_count": len(children),
            "reason": reason,
        }
        value = {
            "schema": 2,
            "launch_id": self.arguments.launch_id,
            "keeper_identity": self.keeper_identity,
            "main_identity": self.main_identity,
            "main_started": self.main_started,
            "main_exit_status": self.main_exit_status,
            "status": status,
            "timed_out": self.timed_out,
            "cancelled": self.cancelled,
            "owned_processes": owned,
            "live_processes": sorted(self.live.values(), key=stamp),
            "owned_processes_complete": self.owned_processes_complete,
            "scope_observed": self.scope_observed,
            "scope_error": self.scope_error,
            "cleanup": cleanup,
        }
        contents = json.dumps(value, sort_keys=True, separators=(",", ":")).encode("utf-8")
        if len(contents) > MAX_STATUS_BYTES:
            raise OSError(errno.EFBIG, "Keeper receipt exceeds its bound")
        if contents == self.last_status:
            self.last_write = time.monotonic()
            return
        temporary = self.filename + ".staging"
        descriptor = os.open(
            temporary,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
            0o600,
            dir_fd=self.directory,
        )
        try:
            with os.fdopen(descriptor, "wb") as destination:
                destination.write(contents)
                destination.flush()
                os.fsync(destination.fileno())
            os.replace(
                temporary, self.filename, src_dir_fd=self.directory, dst_dir_fd=self.directory
            )
            os.fsync(self.directory)
        except BaseException:
            try:
                os.unlink(temporary, dir_fd=self.directory)
            except FileNotFoundError:
                pass
            raise
        self.last_status = contents
        self.last_write = time.monotonic()

    def run(self):
        if not self.await_acknowledgement():
            return 125
        self.spawn()
        while True:
            now = time.monotonic()
            self.timed_out = self.timed_out or now >= self.deadline
            no_children = self.reap()
            children = self.children()
            for pid in children[:MAX_IDENTITIES]:
                process = identity(pid, self.boot_id)
                if process is not None and process["parent_pid"] == self.pid:
                    self.observe(process)
                    if pid == self.main_pid:
                        self.main_identity = process
            self.observe_descendants(children)

            if no_children and self.main_started and self.main_exit_status is not None:
                self.persist("settled", None, True, [])
                return self.main_exit_status

            if self.stop_started is None and (
                self.cancelled or self.timed_out or self.main_exit_status is not None
            ):
                self.stop_started = now
            if self.stop_started is not None:
                self.signal_children(children, now)
                status = (
                    "uncertain"
                    if now - self.stop_started >= UNCERTAIN_AFTER_SECONDS
                    else "settling"
                )
                if self.scope_error:
                    reason = self.scope_error
                elif self.cancelled:
                    reason = "cancelled"
                elif self.timed_out:
                    reason = "timed_out"
                elif self.main_exit_status is not None:
                    reason = "main_exited"
                else:
                    reason = "cleanup_pending"
                self.persist(status, reason, False, children)
            elif now - self.last_write >= 0.1:
                self.persist("running", None, False, children)
            time.sleep(0.02 if self.stop_started is not None else 0.05)


def arguments():
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--status", required=True)
    parser.add_argument("--launch-id", required=True)
    parser.add_argument("--timeout-ms", required=True, type=int)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    result = parser.parse_args()
    if result.command and result.command[0] == "--":
        result.command = result.command[1:]
    if (
        not os.path.isabs(result.status)
        or not result.command
        or not os.path.isabs(result.command[0])
        or result.timeout_ms <= 0
        or str(uuid.UUID(result.launch_id)) != result.launch_id
    ):
        parser.error("invalid private keeper arguments")
    return result


if __name__ == "__main__":
    keeper = None
    try:
        keeper = Keeper(arguments())
        result = keeper.run()
    except BaseException:
        # No argv, environment values or candidate text enter keeper diagnostics.
        try:
            os.write(2, b"Candidate process keeper failed; cleanup authority is unavailable.\n")
        except OSError:
            pass
        if keeper is None or not keeper.spawn_attempted:
            result = 125
        else:
            # A failed receipt cannot justify orphaning still-owned children. Keep
            # the subreaper alive and settle with identity-bound signals even when
            # durable status is unavailable; callers must retain uncertainty.
            keeper.incomplete("keeper_receipt_unavailable")
            while True:
                if keeper.reap():
                    break
                keeper.signal_children(keeper.children(), time.monotonic())
                time.sleep(0.02)
            result = 125
    sys.exit(result)
