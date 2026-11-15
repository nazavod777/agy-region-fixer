import errno
import inspect
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
import unittest

if os.name == "posix":
    import fcntl
    import pty
    import select
    import termios


ROOT = Path(__file__).resolve().parents[1]
SCRATCH = Path(tempfile.gettempdir()) / "agy-runtime-regressions"
BASH = "/bin/bash" if Path("/bin/bash").is_file() else shutil.which("bash")
TERMINAL_WAIT_SECONDS = 8
TERMINAL_OUTPUT_LIMIT = 65536


def process_details(pid):
    """Identify an exact process instance, including a zombie's state."""
    try:
        stat = Path("/proc/%s/stat" % pid).read_text(encoding="utf-8")
    except FileNotFoundError:
        if sys.platform.startswith("linux"):
            return None
    else:
        fields = stat.rsplit(")", 1)[1].split()
        return {"pid": pid, "identity": fields[19], "state": fields[0],
                "pgid": int(fields[2])}
    result = subprocess.run(
        ["ps", "-p", str(pid), "-o", "stat=", "-o", "lstart=", "-o", "pgid="],
        capture_output=True, text=True, timeout=2,
    )
    if not result.stdout.strip():
        return None
    fields = result.stdout.split()
    return {"pid": pid, "identity": " ".join(fields[1:-1]), "state": fields[0],
            "pgid": int(fields[-1])}


@unittest.skipUnless(os.name == "posix" and BASH, "Unix Bash is unavailable")
class UnixRuntimeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        source = (ROOT / "install.sh").read_text(encoding="utf-8")
        prologue = re.search(r"^set -euo pipefail\n.*?(?=^OS=)", source, re.M | re.S)
        if prologue is None:
            raise AssertionError("Installer signal and cleanup setup is missing")
        cls.prologue = prologue[0]
        cls.helpers = {}
        for name in ("run_with_timeout", "capture_owner_path", "select_proxy_port"):
            match = re.search(r"^" + name + r"\(\) \{\n.*?^\}", source, re.M | re.S)
            if match is None:
                raise AssertionError("Installer helper is missing: " + name)
            cls.helpers[name] = match[0]

    def setUp(self):
        SCRATCH.mkdir(exist_ok=True)
        self.directory = tempfile.TemporaryDirectory(prefix="run-", dir=SCRATCH)
        self.addCleanup(self.directory.cleanup)
        self.path = Path(self.directory.name)
        self.ledger = self.path / "processes.jsonl"
        self.capture_path = self.path / "capture-path.txt"
        self.shell_trace = self.path / "shell-trace.txt"
        self.addCleanup(self.cleanup_capture_file)
        self.ready = self.path / "ready"
        os.mkfifo(self.ready)
        self.ready_fd = os.open(self.ready, os.O_RDWR | os.O_NONBLOCK)
        self.addCleanup(os.close, self.ready_fd)
        self.addCleanup(self.cleanup_owned_processes)
        self.env = dict(os.environ, PYBIN=sys.executable, TMPDIR=str(self.path),
                        AGY_TEST_PID_FILE=str(self.ledger), AGY_TEST_READY_FILE=str(self.ready),
                        AGY_TEST_CAPTURE_PATH=str(self.capture_path),
                        AGY_TEST_SHELL_TRACE_FILE=str(self.shell_trace))
        for name in ("BASH_ENV", "ENV"):
            self.env.pop(name, None)

    def owned_processes(self):
        if not self.ledger.exists():
            return []
        return [json.loads(line) for line in self.ledger.read_text(encoding="utf-8").splitlines()]

    def live_owned_processes(self):
        live = {}
        for recorded in self.owned_processes():
            current = process_details(recorded["pid"])
            if (current and current["identity"] == recorded["identity"]
                    and not current["state"].startswith("Z")):
                live[recorded["pid"]] = current
        return list(live.values())

    def cleanup_owned_processes(self):
        for process in self.live_owned_processes():
            try:
                os.kill(process["pid"], signal.SIGKILL)
            except ProcessLookupError:
                pass
        self.wait_for_owned_processes(timeout=3)

    def cleanup_capture_file(self):
        if self.capture_path.exists():
            Path(self.capture_path.read_text(encoding="utf-8").rstrip("\n")).unlink(missing_ok=True)

    def wait_for_owned_processes(self, timeout):
        deadline = time.monotonic() + timeout
        for process in self.live_owned_processes():
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                break
            if hasattr(os, "pidfd_open"):
                try:
                    descriptor = os.pidfd_open(process["pid"])
                except ProcessLookupError:
                    continue
                try:
                    select.select([descriptor], [], [], remaining)
                finally:
                    os.close(descriptor)
            else:
                with select.kqueue() as queue:
                    event = select.kevent(
                        process["pid"], filter=select.KQ_FILTER_PROC,
                        flags=select.KQ_EV_ADD | select.KQ_EV_ONESHOT,
                        fflags=select.KQ_NOTE_EXIT,
                    )
                    try:
                        queue.control([event], 1, remaining)
                    except ProcessLookupError:
                        pass

    def assert_owned_processes_stopped(self):
        self.assertTrue(self.owned_processes(), "The fixture did not record any owned process")
        self.wait_for_owned_processes(timeout=3)
        self.assertEqual(self.live_owned_processes(), [], "Owned processes survived the helper")

    def fixture(self, body):
        script = self.path / "fixture.py"
        script.write_text(
            "import json, os, signal, subprocess, sys\nfrom pathlib import Path\n"
            + inspect.getsource(process_details) + """

def record_process(pid):
    details = process_details(pid)
    if details is not None:
        descriptor = os.open(os.environ['AGY_TEST_PID_FILE'],
                             os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
        try:
            os.write(descriptor, (json.dumps(details) + '\\n').encode())
        finally:
            os.close(descriptor)

def ready():
    with open(os.environ['AGY_TEST_READY_FILE'], 'w', encoding='utf-8') as output:
        output.write('ready\\n')

record_process(os.getpid())
record_process(os.getppid())
""" + body,
            encoding="utf-8",
        )
        return '"$PYBIN" -I ' + shlex.quote(str(script))

    def shell_source(self, body):
        return (self.prologue + self.helpers["run_with_timeout"] + "\n"
                + self.helpers["capture_owner_path"] + """

# Record the platform mktemp result: macOS can choose its user temp directory
# before TMPDIR. Keep the actual command and its arguments unchanged.
mktemp() {
  local path
  path="$(command mktemp "$@")" || return
  printf '%s\\n' "$path" > "$AGY_TEST_CAPTURE_PATH"
  printf '%s\\n' "$path"
}
""" + body)

    def run_shell(self, body, timeout=8):
        process = subprocess.Popen(
            [BASH, "-o", "pipefail", "-c", self.shell_source(body)],
            env=self.env, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, text=True, start_new_session=True,
        )
        try:
            stdout, stderr = process.communicate(timeout=timeout)
        except BaseException:
            self.cleanup_owned_processes()
            if process.poll() is None:
                process.kill()
            process.communicate(timeout=3)
            raise
        return subprocess.CompletedProcess(process.args, process.returncode, stdout, stderr)

    def wait_ready(self):
        readable, _, _ = select.select([self.ready_fd], [], [], 5)
        self.assertTrue(readable, "The owned fixture did not become ready")
        self.assertEqual(os.read(self.ready_fd, 64), b"ready\n")

    def run_in_terminal(self, body, interrupt=None, signal_group=True):
        script = self.path / "terminal.sh"
        script.write_text(self.shell_source(body), encoding="utf-8")
        master, slave = pty.openpty()

        def terminal_session():
            os.setsid()
            fcntl.ioctl(0, termios.TIOCSCTTY, 0)

        process = subprocess.Popen(
            [BASH, str(script)], env=self.env, stdin=slave, stdout=slave, stderr=slave,
            preexec_fn=terminal_session,
        )
        os.close(slave)
        output = bytearray()
        capture_file = None
        try:
            if interrupt is not None:
                self.wait_ready()
                capture_file = Path(self.capture_path.read_text(encoding="utf-8").rstrip("\n"))
                self.assertTrue(capture_file.is_file(), "The capture did not create its recorded temporary file")
                if interrupt == signal.SIGINT:
                    os.write(master, b"\x03")
                elif signal_group:
                    os.killpg(process.pid, interrupt)
                else:
                    os.kill(process.pid, interrupt)
            status = self.read_terminal_until_exit(process, master, output)
            if capture_file is not None:
                self.assertFalse(capture_file.exists(), "Cancellation left the captured PATH file behind")
            return status, output.decode("utf-8", errors="replace")
        except Exception as error:
            diagnostics = self.terminal_diagnostics(process, master, output)
            self.cleanup_owned_processes()
            if process.poll() is None:
                process.kill()
            process.wait(timeout=3)
            raise AssertionError(diagnostics) from error
        except BaseException:
            self.cleanup_owned_processes()
            if process.poll() is None:
                process.kill()
            process.wait(timeout=3)
            raise
        finally:
            os.close(master)

    def read_terminal_until_exit(self, process, master, output):
        # A PTY writer, and macOS slave close itself, can wait for pending output.
        # Drain while the process runs rather than waiting for its exit first.
        deadline = time.monotonic() + TERMINAL_WAIT_SECONDS
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise subprocess.TimeoutExpired(process.args, TERMINAL_WAIT_SECONDS)
            process.poll()
            readable, _, _ = select.select([master], [], [], remaining)
            if not readable:
                raise subprocess.TimeoutExpired(process.args, TERMINAL_WAIT_SECONDS)
            try:
                chunk = os.read(master, 4096)
            except OSError as error:
                if error.errno != errno.EIO:
                    raise
                chunk = b""
            if not chunk:
                return process.wait(timeout=max(0, deadline - time.monotonic()))
            available = TERMINAL_OUTPUT_LIMIT - len(output)
            output.extend(chunk[:available])
            self.assertLessEqual(len(chunk), available, "Unexpected unbounded terminal output")

    def terminal_diagnostics(self, process, master, output):
        # Snapshot identities and states before diagnostic reads can unblock exit.
        details = []
        for pid in sorted({process.pid} | {item["pid"] for item in self.owned_processes()}):
            current = process_details(pid)
            if current is not None:
                try:
                    current["sid"] = os.getsid(pid)
                except ProcessLookupError:
                    continue
            details.append(current if current is not None else {"pid": pid, "state": "absent"})
        deadline = time.monotonic() + 0.2
        while len(output) < TERMINAL_OUTPUT_LIMIT:
            readable, _, _ = select.select([master], [], [], max(0, deadline - time.monotonic()))
            if not readable:
                break
            try:
                chunk = os.read(master, min(4096, TERMINAL_OUTPUT_LIMIT - len(output)))
            except OSError as error:
                if error.errno != errno.EIO:
                    raise
                break
            if not chunk:
                break
            output.extend(chunk)
            if time.monotonic() >= deadline:
                break
        capture = (self.capture_path.read_text(encoding="utf-8").rstrip("\n")
                   if self.capture_path.exists() else None)
        trace = ""
        if self.shell_trace.exists():
            with self.shell_trace.open("rb") as log:
                log.seek(0, os.SEEK_END)
                log.seek(max(0, log.tell() - 16384))
                trace = log.read().decode("utf-8", errors="replace")
        return ("Terminal command failed; processes=%r; TMPDIR=%r; capture=%r; files=%r; output=%r; shell_trace=%r"
                % (details, self.env["TMPDIR"], capture,
                   sorted(path.name for path in self.path.iterdir()),
                   output.decode("utf-8", errors="replace"), trace))

    def test_interactive_login_path_works_in_a_real_terminal(self):
        home = self.path / "home"
        home.mkdir()
        expected = str(home / "interactive-bin") + ":/usr/bin:/bin"
        (home / ".bash_profile").write_text('. "$HOME/.bashrc"\n', encoding="utf-8")
        (home / ".bashrc").write_text(
            'case $- in *i*) ;; *) return ;; esac\nexport PATH=' + shlex.quote(expected) + "\n",
            encoding="utf-8",
        )
        command = self.fixture("""
trace_fd = os.open(os.environ['AGY_TEST_SHELL_TRACE_FILE'],
                   os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
os.dup2(trace_fd, 2)
os.close(trace_fd)
os.execve(%r, [%r, '-xlic', %r], %r)
""" % (
            BASH, BASH, 'printf "\\n@@AGYPATH@@%s@@\\n" "$PATH"',
            {"HOME": str(home), "USER": "synthetic", "TERM": "dumb"},
        ))
        status, output = self.run_in_terminal("""
capture_owner_path """ + command + """
printf 'OWNER_PATH=%s\\n' "$OWNER_PATH"
""")
        self.assertEqual(status, 0, output)
        self.assertIn("OWNER_PATH=" + expected, output)

    def test_terminal_output_is_drained_while_the_process_runs(self):
        payload_size = 32768
        command = self.fixture("sys.stdout.buffer.write(b'x' * %s)\nsys.stdout.buffer.flush()\n" % payload_size)
        status, output = self.run_in_terminal(command)
        self.assertEqual(status, 0)
        self.assertEqual(output, "x" * payload_size)
        self.assert_owned_processes_stopped()

    def test_stopped_command_cannot_defeat_the_timeout(self):
        command = self.fixture("os.kill(os.getpid(), signal.SIGSTOP)\n")
        result = self.run_shell("run_with_timeout 1 " + command)
        self.assertEqual(result.returncode, 124, result.stderr)
        self.assert_owned_processes_stopped()

    def test_term_ignoring_command_cannot_defeat_the_timeout(self):
        command = self.fixture("signal.signal(signal.SIGTERM, signal.SIG_IGN)\nsignal.pause()\n")
        result = self.run_shell("run_with_timeout 1 " + command)
        self.assertEqual(result.returncode, 124, result.stderr)
        self.assert_owned_processes_stopped()

    def test_descendant_holding_stdout_is_cleaned_after_leader_exits(self):
        command = self.descendant_fixture()
        result = self.run_shell("run_with_timeout 3 " + command)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_owned_processes_stopped()

    def descendant_fixture(self, separate_group=False):
        return self.fixture("""
read_fd, write_fd = os.pipe()
if os.fork() == 0:
    os.close(read_fd)
    if """ + repr(separate_group) + """:
        os.setpgrp()
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    record_process(os.getpid())
    os.write(write_fd, b'ready')
    os.close(write_fd)
    signal.pause()
    os._exit(0)
os.close(write_fd)
assert os.read(read_fd, 5) == b'ready'
os.close(read_fd)
""")

    def test_descendant_in_separate_process_group_is_cleaned(self):
        command = self.descendant_fixture(separate_group=True)
        result = self.run_shell("run_with_timeout 3 " + command)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_owned_processes_stopped()

    def test_command_status_is_preserved(self):
        command = self.fixture("sys.exit(23)\n")
        result = self.run_shell("run_with_timeout 3 " + command)
        self.assertEqual(result.returncode, 23, result.stderr)
        self.assert_owned_processes_stopped()

    def check_owner_path_interrupt(self, interrupt, expected, signal_group=True):
        preserved = self.path / "preserved.txt"
        preserved.write_text("Unrelated synthetic file\n", encoding="utf-8")
        command = self.fixture("""
signal.signal(signal.SIGTERM, signal.SIG_IGN)
read_fd, write_fd = os.pipe()
if os.fork() == 0:
    os.close(read_fd)
    record_process(os.getpid())
    os.write(write_fd, b'ready')
    os.close(write_fd)
    signal.pause()
    os._exit(0)
os.close(write_fd)
assert os.read(read_fd, 5) == b'ready'
os.close(read_fd)
ready()
signal.pause()
""")
        status, output = self.run_in_terminal("""
capture_owner_path """ + command + """
printf 'UNEXPECTED_COMPLETION\\n'
""", interrupt=interrupt, signal_group=signal_group)
        self.assertEqual(status, expected, output)
        self.assertNotIn("UNEXPECTED_COMPLETION", output)
        self.assertEqual(preserved.read_text(encoding="utf-8"), "Unrelated synthetic file\n")
        self.assert_owned_processes_stopped()

    def test_ctrl_c_cancels_owner_path_capture(self):
        self.check_owner_path_interrupt(signal.SIGINT, 130)

    def test_sigterm_cancels_owner_path_capture(self):
        self.check_owner_path_interrupt(signal.SIGTERM, 143)

    def test_sigterm_to_installer_pid_cancels_owner_path_capture(self):
        self.check_owner_path_interrupt(signal.SIGTERM, 143, signal_group=False)

    def select_port(self, requested="", previous="", active="1"):
        env = dict(self.env, PORT=str(requested), OLD_PORT=str(previous), SERVICE_ACTIVE=active)
        return subprocess.run(
            [BASH, "-c", self.helpers["select_proxy_port"] + "\nselect_proxy_port"],
            env=env, capture_output=True, text=True, timeout=5,
        )

    def bind_high_port(self, listen=False):
        listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.addCleanup(listener.close)
        for port in range(49152, 65536):
            try:
                listener.bind(("127.0.0.1", port))
            except OSError:
                continue
            if listen:
                listener.listen(1)
            return listener, port
        self.fail("No high localhost port is available for the test fixture")

    def assert_bindable(self, port):
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
            listener.bind(("127.0.0.1", port))

    def test_default_port_is_high_and_bindable(self):
        result = self.select_port()
        self.assertEqual(result.returncode, 0, result.stderr)
        port = int(result.stdout)
        self.assertGreaterEqual(port, 49152)
        self.assertLessEqual(port, 65535)
        self.assert_bindable(port)

    def test_saved_idle_high_port_is_reused(self):
        listener, port = self.bind_high_port()
        listener.close()
        result = self.select_port(previous=port)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(int(result.stdout), port)
        self.assert_bindable(port)

    def test_saved_active_service_port_is_reused(self):
        _, port = self.bind_high_port(listen=True)
        result = self.select_port(previous=port, active="0")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(int(result.stdout), port)

    def test_saved_foreign_busy_port_gets_a_free_fallback(self):
        _, busy = self.bind_high_port(listen=True)
        result = self.select_port(previous=busy)
        self.assertEqual(result.returncode, 0, result.stderr)
        selected = int(result.stdout)
        self.assertNotEqual(selected, busy)
        self.assertGreaterEqual(selected, 49152)
        self.assertLessEqual(selected, 65535)
        self.assert_bindable(selected)

    def test_explicit_busy_port_is_refused_even_without_listen(self):
        for listen in (False, True):
            with self.subTest(listen=listen):
                listener, port = self.bind_high_port(listen=listen)
                result = self.select_port(requested=port)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")
                self.assertIn("busy", result.stderr)
                listener.close()

    def test_explicit_free_port_is_selected(self):
        listener, port = self.bind_high_port()
        listener.close()
        result = self.select_port(requested=port)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(int(result.stdout), port)
        self.assert_bindable(port)

    def test_explicit_own_active_port_is_reused(self):
        _, port = self.bind_high_port(listen=True)
        result = self.select_port(requested=port, previous=port, active="0")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(int(result.stdout), port)

    def test_legacy_low_saved_port_is_replaced_with_a_high_port(self):
        result = self.select_port(previous="8080", active="0")
        self.assertEqual(result.returncode, 0, result.stderr)
        port = int(result.stdout)
        self.assertGreaterEqual(port, 49152)
        self.assertLessEqual(port, 65535)
        self.assert_bindable(port)

    def test_oversized_saved_port_gets_a_valid_fallback(self):
        result = self.select_port(previous="9" * 5000)
        self.assertEqual(result.returncode, 0, result.stderr)
        port = int(result.stdout)
        self.assertGreaterEqual(port, 49152)
        self.assertLessEqual(port, 65535)
        self.assert_bindable(port)


if __name__ == "__main__":
    unittest.main()
