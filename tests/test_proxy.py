import asyncio
import importlib.util
import json
import os
from pathlib import Path
import socket
import tempfile
import unittest
from unittest import mock

from mitmproxy import http
from mitmproxy.addons import script


class ProxyTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        # Match asyncio.run's production mode: unittest's debug stack formatting
        # itself calls linecache/os.stat on executing Python source files.
        asyncio.get_running_loop().set_debug(False)

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="agy-proxy-test-")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.source = self.root / "addon.py"
        template = (Path(__file__).resolve().parents[1] / "addon.py").read_text()
        template = template.replace("@@LOG@@", str(self.root / "mitm.log").replace("\\", "\\\\"))
        template = template.replace("@@VERBOSE_FLAG@@", str(self.root / "verbose.flag").replace("\\", "\\\\"))
        self.source.write_text(template, encoding="utf-8")
        spec = importlib.util.spec_from_file_location("proxy_under_test", self.source)
        self.addon = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.addon)

    async def test_real_proxy_filters_without_script_reloader(self):
        with socket.socket() as reservation:
            reservation.bind(("127.0.0.1", 0))
            port = reservation.getsockname()[1]
        master = self.addon.create_proxy(port, str(self.root / "ca"))
        ready = asyncio.Event()

        class Ready:
            def running(self):
                ready.set()

        class SyntheticUpstream:
            def request(self, flow):
                flow.response = http.Response.make(200, json.dumps({
                    "ineligibleTiers": [{"reasonCode": "UNSUPPORTED_LOCATION"}],
                    "allowedTiers": [{"id": "synthetic-tier"}],
                }), {"content-type": "application/json"})

        master.addons.add(Ready(), SyntheticUpstream())
        self.assertEqual(master.options.listen_host, "127.0.0.1")
        self.assertEqual(master.options.scripts, [])
        self.assertIsNone(master.addons.get("scriptloader"))
        real_stat = os.stat
        addon_stats = []

        def track_stat(path, *args, **kwargs):
            if isinstance(path, (str, bytes, os.PathLike)) and os.fsdecode(path) == str(self.source):
                addon_stats.append(path)
            return real_stat(path, *args, **kwargs)

        with mock.patch.object(script.os, "stat", side_effect=track_stat):
            task = asyncio.create_task(self.addon.serve_proxy(master))
            try:
                readiness = asyncio.create_task(ready.wait())
                done, _ = await asyncio.wait({task, readiness}, timeout=10,
                                             return_when=asyncio.FIRST_COMPLETED)
                if task in done:
                    await task
                    self.fail("Proxy exited before readiness")
                self.assertIn(readiness, done, "Proxy did not become ready")
                reader, writer = await asyncio.wait_for(asyncio.open_connection("127.0.0.1", port), 5)
                try:
                    writer.write(b"GET http://synthetic.googleapis.com/test HTTP/1.1\r\n"
                                 b"Host: synthetic.googleapis.com\r\nConnection: close\r\n\r\n")
                    await asyncio.wait_for(writer.drain(), 5)
                    response = await asyncio.wait_for(reader.read(65536), 5)
                    self.assertIn(b"200 OK", response.split(b"\r\n", 1)[0])
                    body = json.loads(response.split(b"\r\n\r\n", 1)[1])
                    self.assertEqual(body["ineligibleTiers"], [])
                    self.assertEqual(body["allowedTiers"], [{"id": "synthetic-tier"}])
                finally:
                    writer.close()
                    await writer.wait_closed()
                # Elapsed time is the assertion: allow a legacy reload tick to
                # happen, then prove this process did not stat its addon file.
                await asyncio.sleep(script.ReloadInterval + 0.1)
                self.assertEqual(addon_stats, [])
                self.assertTrue((self.root / "ca" / "mitmproxy-ca-cert.pem").exists())
            finally:
                if not readiness.done():
                    readiness.cancel()
                    await asyncio.gather(readiness, return_exceptions=True)
                master.shutdown()
                await asyncio.wait_for(task, 5)

    async def test_stat_probe_detects_legacy_reloader(self):
        # Negative control for the no-poll assertion: the old Script watcher
        # must be observable through the exact same stat instrumentation.
        source = self.root / "control.py"
        source.write_text("name = 'synthetic-control'\n")
        calls = []
        real_stat = os.stat

        def track_stat(path, *args, **kwargs):
            if path == str(source):
                calls.append(path)
            return real_stat(path, *args, **kwargs)

        master = self.addon.create_proxy(0, str(self.root / "control-ca"))
        watcher = None
        with mock.patch.object(script.os, "stat", side_effect=track_stat):
            try:
                watcher = script.Script(str(source), reload=True)
                await asyncio.sleep(script.ReloadInterval + 0.1)
                self.assertGreaterEqual(len(calls), 2)
            finally:
                if watcher is not None:
                    watcher.done()
                    await asyncio.gather(watcher.reloadtask, return_exceptions=True)
                await master.done()

    async def test_hook_only_custom_addon_loads_once(self):
        custom = self.root / "custom-addon.py"
        counter = self.root / "loads.txt"
        custom.write_text(
            "from pathlib import Path\n"
            f"counter = Path({str(counter)!r})\n"
            "counter.write_text(counter.read_text() + 'load\\n' if counter.exists() else 'load\\n')\n"
            "def response(flow):\n"
            "    flow.response.headers['x-synthetic-addon'] = 'loaded'\n",
            encoding="utf-8",
        )
        master = self.addon.create_proxy(0, str(self.root / "custom-ca"), str(custom))
        try:
            self.assertIsNone(master.addons.get("scriptloader"))
            custom_addon = master.addons.get("agy-custom-addon")
            self.assertIsNotNone(custom_addon)
            flow = type("Flow", (), {"response": http.Response.make(200)})()
            custom_addon.response(flow)
            self.assertEqual(flow.response.headers["x-synthetic-addon"], "loaded")
            custom.write_text("raise RuntimeError('must not reload')\n", encoding="utf-8")
            await asyncio.sleep(script.ReloadInterval + 0.1)
            custom_addon.response(flow)
            self.assertEqual(counter.read_text(), "load\n")
        finally:
            await master.done()


if __name__ == "__main__":
    unittest.main()
