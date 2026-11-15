import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
CASES = (
    ("BYPASS_OK\n", 0, True),
    ("fake-agy -p Reply exactly: BYPASS_OK\n", 0, False),
    ("BYPASS_OK\n", 1, False),
    ("BYPASS_OK\n", 124, False),
    ("\x1b[32mBYPASS_OK\x1b[0m\n", 0, True),
    ("BYPASS_OK_EXTRA\n", 0, False),
    ("bypass_ok\n", 0, False),
    ("BYPASS_OK\n" + "synthetic trailing diagnostic\n" * 10000, 0, True),
)


class SmokeTests(unittest.TestCase):
    def test_unix_requires_a_successful_exact_reply(self):
        bash = "/bin/bash" if Path("/bin/bash").is_file() else shutil.which("bash")
        if not bash:
            self.skipTest("Bash is unavailable")
        source = (ROOT / "install.sh").read_text(encoding="utf-8")
        match = re.search(r"^smoke_succeeded\(\) \{\n.*?^\}", source, re.M | re.S)
        self.assertIsNotNone(match, "Installer smoke helper is missing")
        with tempfile.TemporaryDirectory(prefix="agy-smoke-test-") as directory:
            output = Path(directory) / "output.txt"
            for text, status, expected in CASES:
                with self.subTest(output=text[:120], status=status):
                    output.write_text(text, encoding="utf-8")
                    result = subprocess.run(
                        [bash, "-o", "pipefail", "-c", match[0] + '\nsmoke_succeeded "$1" "$2"',
                         "smoke-test", str(status), str(output)],
                        capture_output=True, text=True, timeout=10,
                    )
                    self.assertEqual(result.returncode, 0 if expected else 1, result.stderr)

    def test_windows_requires_a_successful_exact_reply(self):
        powershell = shutil.which("powershell") or shutil.which("pwsh")
        if not powershell:
            self.skipTest("PowerShell is unavailable")
        source = (ROOT / "install.ps1").read_text(encoding="utf-8")
        match = re.search(r"^function Test-SmokeSuccess\(.*?^\}", source, re.M | re.S)
        self.assertIsNotNone(match, "Installer smoke helper is missing")
        with tempfile.TemporaryDirectory(prefix="agy-smoke-test-") as directory:
            script = Path(directory) / "check.ps1"
            case_file = Path(directory) / "case.json"
            script.write_text(match[0] + """
$ErrorActionPreference = 'Stop'
$case = ConvertFrom-Json ([IO.File]::ReadAllText($env:AGY_SMOKE_CASE_FILE))
if (Test-SmokeSuccess $case.status @($case.output -split "`n")) { exit 0 }
exit 1
""", encoding="utf-8-sig")
            for text, status, expected in CASES:
                with self.subTest(output=text[:120], status=status):
                    case_file.write_text(json.dumps({"output": text, "status": status}), encoding="utf-8")
                    env = dict(os.environ, AGY_SMOKE_CASE_FILE=str(case_file))
                    result = subprocess.run(
                        [powershell, "-NoProfile", "-NonInteractive", "-File", str(script)],
                        env=env, capture_output=True, text=True, timeout=10,
                    )
                    self.assertEqual(result.returncode, 0 if expected else 1, result.stderr)


if __name__ == "__main__":
    unittest.main()
