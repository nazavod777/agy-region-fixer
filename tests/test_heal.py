import os
import plistlib
from pathlib import Path
import re
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
import unittest


ROOT = Path(__file__).resolve().parents[1]
BASH = "/bin/bash" if Path("/bin/bash").is_file() else shutil.which("bash")


@unittest.skipUnless(os.name == "posix" and BASH, "Unix Bash is unavailable")
class UnixHealTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = (ROOT / "install.sh").read_text(encoding="utf-8")
        cls.common = cls.source.split("cat <<'COMMONEOF'\n", 1)[1].split("\nCOMMONEOF", 1)[0]
        cls.heal_source = cls.source.split("cat <<'HEALEOF'\n", 1)[1].split("\nHEALEOF", 1)[0]

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="agy-heal-test-")
        self.addCleanup(self.directory.cleanup)
        self.path = Path(self.directory.name)
        self.prefix = self.path / "prefix"
        self.prefix.mkdir()
        self.bin = self.path / "bin"
        self.bin.mkdir()
        self.target = self.bin / "agy"
        self.real = self.bin / "agy.real"
        self.entry = self.target
        self.ready = self.path / "ready"
        python = self.prefix / "venv" / "bin" / "python"
        python.parent.mkdir(parents=True)
        # Exercise the generated helper unchanged. Only the test interpreter
        # wrapper injects deterministic races or filesystem failures.
        python.write_text("#!" + sys.executable + "\n" + """
import os
from pathlib import Path
import sys
import time
source = sys.stdin.read()
sys.argv = ["-"] + sys.argv[3:]
original_sleep = time.sleep
def observed_sleep(seconds):
    Path(os.environ["AGY_TEST_READY"]).touch()
    original_sleep(seconds)
time.sleep = observed_sleep
exec(os.environ.get("AGY_TEST_INJECT", "") + "\\n" + source)
""", encoding="utf-8")
        python.chmod(0o755)
        self.common_path = self.prefix / "common.sh"
        self.common_path.write_text(
            "PREFIX_SH=" + shlex.quote(str(self.prefix)) + "\n"
            + "PORT_SH=8090\nCA_SH=" + shlex.quote(str(self.prefix / "ca")) + "\n"
            + self.common + "\n"
            # Keep the real 500 ms quiet window, but shorten failure deadlines
            # and use small synthetic files in these isolated regression cases.
            + "MIN_REAL_BYTES=2048\nHEAL_WAIT_SECONDS=1.3\nHEAL_MISSING_SECONDS=0.6\n",
            encoding="utf-8",
        )
        self.heal_path = self.prefix / "heal.sh"
        self.heal_path.write_text(
            "#!/bin/bash\nSELF=" + shlex.quote(str(self.heal_path)) + "\n. "
            + shlex.quote(str(self.common_path)) + "\n" + self.heal_source + "\n",
            encoding="utf-8",
        )
        self.heal_path.chmod(0o755)
        self.env = dict(os.environ, AGY_TEST_READY=str(self.ready))
        for name in ("BASH_ENV", "ENV", "AGY_HEAL_LOCKED"):
            self.env.pop(name, None)
        self.old = self.binary("previous")
        self.updated = self.binary("updated")
        self.real.write_bytes(self.old)
        self.real.chmod(0o755)
        self.target.write_bytes(self.updated)
        self.target.chmod(0o755)
        self.register(self.entry)

    def binary(self, label):
        return ("#!/bin/sh\nprintf '" + label + "\\n'\n#").encode().ljust(4096, b"x")

    def register(self, entry):
        self.entry = entry
        (self.prefix / "shim.path").write_text(str(entry) + "\n", encoding="utf-8")

    def start_heal(self, *args, inject=""):
        process = subprocess.Popen(
            [BASH, str(self.heal_path), *map(str, args)],
            env=dict(self.env, AGY_TEST_INJECT=inject),
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
            start_new_session=True,
        )
        self.addCleanup(self.stop_process, process)
        return process

    def stop_process(self, process):
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.communicate(timeout=5)

    def finish(self, process):
        stdout, stderr = process.communicate(timeout=5)
        self.assertEqual(process.returncode, 0, stdout + stderr)
        return stdout + stderr

    def heal(self, *args, inject=""):
        return self.finish(self.start_heal(*args, inject=inject))

    def wait_ready(self):
        deadline = time.monotonic() + 3
        while not self.ready.exists():
            self.assertLess(time.monotonic(), deadline, "Readiness observation did not start")
            time.sleep(0.01)

    def assert_repaired(self, expected=None):
        self.assertIn(b"agy-region-fixer-shim", self.target.read_bytes())
        self.assertEqual(self.real.read_bytes(), self.updated if expected is None else expected)
        self.assertTrue(os.access(self.target, os.X_OK))
        self.assertTrue(os.access(self.real, os.X_OK))
        stage = self.bin / ".agy-region-fixer-stage"
        self.assertEqual(list(stage.iterdir()), [])

    def test_inplace_update_is_staged_and_repaired(self):
        output = self.heal("--event")
        self.assertIn("restored", output)
        self.assert_repaired()

    def test_atomic_rename_update_is_repaired(self):
        self.heal()
        replacement = self.bin / "download"
        replacement.write_bytes(self.binary("atomic"))
        replacement.chmod(0o755)
        replacement.replace(self.target)
        self.heal("--event")
        self.assert_repaired(self.binary("atomic"))

    def test_own_write_events_are_idempotent(self):
        self.heal("--event")
        before = [(path.stat().st_ino, path.stat().st_mtime_ns)
                  for path in (self.target, self.real)]
        self.assertEqual(self.heal("--event"), "")
        self.assertEqual(self.heal("--event"), "")
        self.assertEqual(before, [(path.stat().st_ino, path.stat().st_mtime_ns)
                                  for path in (self.target, self.real)])

    def test_shim_refresh_failure_does_not_mutate_the_watched_parent(self):
        self.heal("--event")
        shim = self.target.read_bytes()
        parent_mtime = self.bin.stat().st_mtime_ns
        with self.common_path.open("a", encoding="utf-8") as common:
            common.write("\nPORT_SH=8091\nmv() { return 1; }\n")
        for _ in range(2):
            output = self.heal("--event")
            self.assertIn("FAILED to update shim", output)
            self.assertEqual(self.target.read_bytes(), shim)
            self.assertEqual(self.real.read_bytes(), self.updated)
            self.assertEqual(self.bin.stat().st_mtime_ns, parent_mtime)
            self.assertEqual(list((self.bin / ".agy-region-fixer-stage").iterdir()), [])

    def test_shim_refresh_refuses_a_symlinked_staging_directory(self):
        self.heal("--event")
        shim = self.target.read_bytes()
        stage = self.bin / ".agy-region-fixer-stage"
        stage.rmdir()
        victim = self.path / "foreign-stage"
        victim.mkdir()
        stage.symlink_to(victim)
        with self.common_path.open("a", encoding="utf-8") as common:
            common.write("\nPORT_SH=8091\n")
        parent_mtime = self.bin.stat().st_mtime_ns
        self.assertIn("Blocked", self.heal("--event"))
        self.assertEqual(self.target.read_bytes(), shim)
        self.assertEqual(self.real.read_bytes(), self.updated)
        self.assertEqual(list(victim.iterdir()), [])
        self.assertEqual(self.bin.stat().st_mtime_ns, parent_mtime)

    def test_delete_then_create_is_not_overwritten_during_grace(self):
        self.target.unlink()
        process = self.start_heal("--event")
        self.wait_ready()
        self.assertFalse(self.target.exists())
        self.assertEqual(self.real.read_bytes(), self.old)
        self.target.write_bytes(self.updated)
        self.target.chmod(0o755)
        self.finish(process)
        self.assert_repaired()

    def test_missing_event_stays_pending_but_timer_recovers(self):
        self.target.unlink()
        output = self.heal("--event")
        self.assertIn("Pending", output)
        self.assertFalse(self.target.exists())
        self.assertEqual(self.real.read_bytes(), self.old)
        self.assertFalse((self.bin / ".agy-region-fixer-stage").exists())
        self.heal()
        self.assert_repaired(self.old)

    def test_owner_worker_keeps_missing_event_mode(self):
        with self.common_path.open("a", encoding="utf-8") as common:
            common.write("""
owner_user() { printf synthetic; }
entry_mode() { printf owner; }
drop_to_owner() { "$@"; }
""")
        self.target.unlink()
        self.assertIn("Pending", self.heal("--event"))
        self.assertFalse(self.target.exists())
        self.assertEqual(self.real.read_bytes(), self.old)

    def test_same_size_writes_with_restored_mtime_do_not_replace_original(self):
        stopped = threading.Event()
        observed_mtime = self.target.stat().st_mtime_ns

        def write_updates():
            while not stopped.is_set():
                with self.target.open("r+b") as output:
                    output.seek(128)
                    output.write(b"z")
                    output.flush()
                    os.fsync(output.fileno())
                os.utime(self.target, ns=(observed_mtime, observed_mtime))
                stopped.wait(0.03)

        writer = threading.Thread(target=write_updates)
        writer.start()
        try:
            output = self.heal("--event")
        finally:
            stopped.set()
            writer.join(timeout=3)
        self.assertFalse(writer.is_alive())
        self.assertIn("Pending", output)
        self.assertEqual(self.target.stat().st_size, len(self.updated))
        self.assertEqual(self.real.read_bytes(), self.old)
        self.assertFalse((self.bin / ".agy-region-fixer-stage").exists())
        self.heal("--event")
        self.assertEqual(self.real.read_bytes()[128:129], b"z")

    def test_same_size_atomic_replacement_while_waiting_uses_latest_inode(self):
        process = self.start_heal("--event")
        self.wait_ready()
        replacement = self.bin / "latest"
        payload = self.binary("latest")
        replacement.write_bytes(payload)
        replacement.chmod(0o755)
        replacement.replace(self.target)
        self.finish(process)
        self.assert_repaired(payload)

    def test_candidate_changed_during_copy_stays_pending(self):
        inject = """
import os
original_fsync = os.fsync
def changed_candidate(descriptor):
    original_fsync(descriptor)
    if os.fstat(descriptor).st_size == 4096:
        target = Path(sys.argv[2])
        replacement = target.with_name('replacement')
        replacement.write_bytes(b'new concurrent update'.ljust(4096, b'x'))
        replacement.chmod(0o755)
        replacement.replace(target)
os.fsync = changed_candidate
"""
        output = self.heal("--event", inject=inject)
        self.assertIn("Pending", output)
        self.assertTrue(self.target.read_bytes().startswith(b"new concurrent update"))
        self.assertEqual(self.real.read_bytes(), self.old)
        self.assertEqual(list((self.bin / ".agy-region-fixer-stage").iterdir()), [])

    def test_shim_publication_failure_restores_previous_original(self):
        inject = """
import os
original_replace = os.replace
def failed_publication(source, destination):
    if '.shim.' in str(source):
        raise OSError('synthetic publication failure')
    return original_replace(source, destination)
os.replace = failed_publication
"""
        output = self.heal("--event", inject=inject)
        self.assertIn("Blocked", output)
        self.assertNotIn("[heal] restored:", output)
        self.assertEqual(self.target.read_bytes(), self.updated)
        self.assertEqual(self.real.read_bytes(), self.old)
        stage = self.bin / ".agy-region-fixer-stage"
        self.assertEqual([path.name for path in stage.iterdir()], ["agy.blocked.json"])
        before = (self.target.stat(), self.real.stat())
        output = self.heal("--event", inject=inject)
        self.assertIn("unchanged after a failed repair", output)
        self.assertEqual([(item.st_ino, item.st_mtime_ns, item.st_ctime_ns) for item in before],
                         [(path.stat().st_ino, path.stat().st_mtime_ns, path.stat().st_ctime_ns)
                          for path in (self.target, self.real)])
        # The regular fallback can retry the same candidate after an error clears.
        self.heal()
        self.assert_repaired()

    def test_cancellation_while_staging_preserves_original_and_removes_temps(self):
        inject = """
import os, signal
original_fsync = os.fsync
def cancel_staging(descriptor):
    original_fsync(descriptor)
    if os.fstat(descriptor).st_size == 4096:
        os.kill(os.getpid(), signal.SIGTERM)
os.fsync = cancel_staging
"""
        self.heal("--event", inject=inject)
        self.assertEqual(self.target.read_bytes(), self.updated)
        self.assertEqual(self.real.read_bytes(), self.old)
        self.assertEqual(list((self.bin / ".agy-region-fixer-stage").iterdir()), [])

    def test_small_candidate_preserves_previous_original_without_writes(self):
        self.target.write_bytes(b"junk")
        output = self.heal("--event")
        self.assertIn("Pending", output)
        self.assertEqual(self.target.read_bytes(), b"junk")
        self.assertEqual(self.real.read_bytes(), self.old)
        self.assertFalse((self.bin / ".agy-region-fixer-stage").exists())

    def test_original_symlink_is_refused(self):
        victim = self.path / "victim"
        victim.write_bytes(b"unrelated synthetic file")
        self.real.unlink()
        self.real.symlink_to(victim)
        output = self.heal("--event")
        self.assertIn("Blocked", output)
        self.assertEqual(victim.read_bytes(), b"unrelated synthetic file")
        self.assertEqual(self.target.read_bytes(), self.updated)
        self.assertTrue(self.real.is_symlink())

    def test_setuid_and_setgid_candidates_are_blocked_before_staging(self):
        for mode in (0o4755, 0o2755):
            with self.subTest(mode=oct(mode)):
                self.target.chmod(mode)
                self.assertIn("setuid/setgid", self.heal("--event"))
                self.assertEqual(self.target.read_bytes(), self.updated)
                self.assertEqual(self.real.read_bytes(), self.old)
                self.assertFalse((self.bin / ".agy-region-fixer-stage").exists())

    @unittest.skipUnless(hasattr(os, "geteuid") and os.geteuid() == 0,
                         "Root is required to verify cross-owner copy metadata")
    def test_root_copy_preserves_user_owned_candidate_owner_and_group(self):
        # No account creation or privileged execution: the numeric identities
        # belong only to a fixture below the private temporary directory.
        os.chown(self.target, 10001, 10002)
        self.target.chmod(0o700)
        self.heal("--event")
        self.assert_repaired()
        saved = self.real.stat()
        self.assertEqual((saved.st_uid, saved.st_gid), (10001, 10002))
        self.assertEqual(saved.st_mode & 0o7777, 0o700)

    @unittest.skipUnless(hasattr(os, "geteuid") and os.geteuid() == 0,
                         "Root is required to verify the setuid ownership boundary")
    def test_user_owned_setuid_candidate_cannot_become_root_setuid(self):
        os.chown(self.target, 10001, 10002)
        self.target.chmod(0o4755)
        self.assertIn("Blocked", self.heal("--event"))
        self.assertEqual((self.target.stat().st_uid, self.target.stat().st_mode & 0o7777),
                         (10001, 0o4755))
        self.assertEqual(self.real.read_bytes(), self.old)
        self.assertEqual(self.real.stat().st_mode & 0o6000, 0)
        self.assertFalse((self.bin / ".agy-region-fixer-stage").exists())

    def test_staging_symlink_is_refused(self):
        victim = self.path / "victim-dir"
        victim.mkdir()
        (self.bin / ".agy-region-fixer-stage").symlink_to(victim)
        self.assertIn("Blocked", self.heal("--event"))
        self.assertEqual(list(victim.iterdir()), [])
        self.assertEqual(self.real.read_bytes(), self.old)
        self.assertEqual(self.target.read_bytes(), self.updated)

    def test_symlink_entry_is_preserved(self):
        entry = self.path / "agy-link"
        entry.symlink_to(self.target)
        self.register(entry)
        self.heal("--event")
        self.assertTrue(entry.is_symlink())
        self.assert_repaired()

    def test_symlink_retarget_during_quiet_does_not_modify_either_binary(self):
        entry = self.path / "agy-link"
        entry.symlink_to(self.target)
        self.register(entry)
        other = self.bin / "other-agy"
        other.write_bytes(self.binary("other"))
        other.chmod(0o755)
        process = self.start_heal("--event")
        self.wait_ready()
        entry.unlink()
        entry.symlink_to(other)
        self.assertIn("Pending", self.finish(process))
        self.assertEqual(self.real.read_bytes(), self.old)
        self.assertEqual(self.target.read_bytes(), self.updated)
        self.assertEqual(other.read_bytes(), self.binary("other"))

    def test_concurrent_heals_keep_original_outside_the_shim(self):
        processes = [self.start_heal("--event") for _ in range(3)]
        output = "".join(self.finish(process) for process in processes)
        self.assertEqual(output.count("[heal] restored:"), 1)
        self.assert_repaired()

    def test_force_install_allows_small_executable_and_uninstall_restores_it(self):
        self.target.write_bytes(b"#!/bin/sh\necho synthetic-small-cli\n")
        expected = self.target.read_bytes()
        self.heal("--place", self.target)
        self.assert_repaired(expected)
        self.heal("--restore")
        self.assertEqual(self.target.read_bytes(), expected)
        self.assertFalse(self.real.exists())
        self.assertFalse((self.bin / ".agy-region-fixer-stage").exists())

    def test_watch_targets_include_paths_and_immediate_parents_once(self):
        helper = re.search(r"^watch_targets\(\) \{\n.*?^\}", self.source, re.M | re.S)
        self.assertIsNotNone(helper)
        entry = self.path / "agy-link"
        entry.symlink_to(self.target)
        self.register(entry)
        result = subprocess.run(
            [BASH, "-c", '. "$1"; PREFIX="$PREFIX_SH"; ' + helper[0] + "\nwatch_targets",
             "watch-test", str(self.common_path)], capture_output=True, text=True, timeout=5,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(set(result.stdout.splitlines()),
                         {str(entry), str(self.path), str(self.target), str(self.bin)})
        self.assertEqual(len(result.stdout.splitlines()), len(set(result.stdout.splitlines())))


@unittest.skipUnless(os.name == "posix" and BASH, "Unix Bash is unavailable")
class UnixProxyLauncherTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = (ROOT / "install.sh").read_text(encoding="utf-8")

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="agy-launcher-test-")
        self.addCleanup(self.directory.cleanup)
        self.path = Path(self.directory.name)
        self.prefix = self.path / "prefix & with spaces"
        self.prefix.mkdir()
        self.default = self.path / "default.py"
        self.default.write_text('LOG = "@@LOG@@"\nBOOTSTRAP = True\n', encoding="utf-8")
        self.custom = self.path / "hooks.py"
        self.custom.write_text('LOG = "@@LOG@@"\naddons = []\n', encoding="utf-8")

    def test_custom_url_keeps_hook_module_separate_from_default_bootstrap(self):
        begin = self.source.index('SCRIPT_DIR=""')
        end = self.source.index('\n# ---------------------------------------------------------------------------', begin)
        fragment = self.source[begin:end]
        xml = next(line for line in self.source.splitlines() if line.startswith("xml_esc()"))
        script = """
set -euo pipefail
CLEAN_ENV=(env)
err() { printf '%s\\n' "$*" >&2; exit 1; }
curl() {
  if [[ "$2" == "$RAW_BASE/addon.py" ]]; then cp "$DEFAULT" "$4";
  elif [[ "$2" == "$AGY_ADDON_URL" ]]; then cp "$CUSTOM" "$4";
  else return 1; fi
}
""" + xml + "\n" + fragment + '\nprintf "%s\\n%s\\n" "$CUSTOM_EXEC_ARGS" "$CUSTOM_PLIST_ARGS"\n'
        result = subprocess.run(
            [BASH, "-c", script], capture_output=True, text=True, timeout=5,
            env=dict(os.environ, PREFIX=str(self.prefix), PYBIN=sys.executable,
                     RAW_BASE="https://example.invalid", DEFAULT=str(self.default),
                     CUSTOM=str(self.custom), AGY_ADDON_URL="file://synthetic-hooks"),
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        default = (self.prefix / "addon.py").read_text(encoding="utf-8")
        custom = (self.prefix / "custom-addon.py").read_text(encoding="utf-8")
        self.assertIn("BOOTSTRAP = True", default)
        self.assertIn("addons = []", custom)
        self.assertNotIn("@@LOG@@", default + custom)
        self.assertIn(str(self.prefix / "mitm.log"), default)
        self.assertIn('--addon "' + str(self.prefix / "custom-addon.py") + '"', result.stdout)
        self.assertIn("prefix &amp; with spaces", result.stdout)

    def render(self, template, custom=False):
        prefix = str(self.prefix)
        env = dict(os.environ, PREFIX=prefix, VENV=prefix + "/venv", PORT="8090",
                   CA_DIR=prefix + "/ca", X_PREFIX=prefix.replace("&", "&amp;"),
                   X_VENV=(prefix + "/venv").replace("&", "&amp;"),
                   X_CA_DIR=(prefix + "/ca").replace("&", "&amp;"),
                   CUSTOM_EXEC_ARGS=(' --addon "' + prefix + '/custom-addon.py"') if custom else "",
                   CUSTOM_PLIST_ARGS=('<string>--addon</string><string>'
                                      + prefix.replace("&", "&amp;")
                                      + '/custom-addon.py</string>') if custom else "")
        result = subprocess.run([BASH, "-c", "cat <<TEMPLATE\n" + template + "\nTEMPLATE"],
                                env=env, capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout

    def test_linux_and_macos_start_the_same_isolated_bootstrap(self):
        linux = self.source.split('cat > /etc/systemd/system/agy-region-fixer.service <<UNIT\n', 1)[1].split('\nUNIT', 1)[0]
        mac = self.source.split('cat > "$PLIST" <<PLISTEOF\n', 1)[1].split('\nPLISTEOF', 1)[0]
        for custom in (False, True):
            with self.subTest(custom=custom):
                unit = self.render(linux, custom)
                command = next(line.split("=", 1)[1] for line in unit.splitlines()
                               if line.startswith("ExecStart="))
                plist = plistlib.loads(self.render(mac, custom).encode())
                expected = [str(self.prefix / "venv/bin/python"), "-I", str(self.prefix / "addon.py"),
                            "--port", "8090", "--confdir", str(self.prefix / "ca")]
                if custom:
                    expected += ["--addon", str(self.prefix / "custom-addon.py")]
                self.assertEqual(shlex.split(command), expected)
                self.assertEqual(plist["ProgramArguments"], expected)


if __name__ == "__main__":
    unittest.main()
