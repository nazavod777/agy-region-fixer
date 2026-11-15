# ============================================================================
# agy-region-fixer — mitmproxy addon (TEMPLATE)
# Single source of truth for the cleaning logic: install.sh and install.ps1
# copy this file and substitute @@LOG@@ and @@VERBOSE_FLAG@@.
# (the file becomes runnable Python only after the installer substitutes them)
# ============================================================================
import json
import os
from mitmproxy import http

LOG = "@@LOG@@"
VERBOSE_FLAG = "@@VERBOSE_FLAG@@"
MAX_LOG = 5 * 1024 * 1024

def _log(s):
    try:
        if os.path.getsize(LOG) > MAX_LOG:
            open(LOG, "w").close()  # simple rotation: the log grew past 5MB, so truncate it
    except OSError:
        pass
    try:
        with open(LOG, "a") as f:
            f.write(s + "\n")
    except OSError:
        pass

def request(flow: http.HTTPFlow):
    # full-URL logging only in verbose mode (for debugging): create <prefix>/verbose.flag;
    # the flag is checked on every request, so it can be toggled without restarting the proxy
    if os.path.exists(VERBOSE_FLAG):
        _log(f"REQ {flow.request.method} {flow.request.pretty_url}")

def response(flow: http.HTTPFlow):
    # clean ONLY responses from Google domains; leave other sites alone
    if not flow.request.pretty_host.endswith(".googleapis.com"):
        return
    try:
        body = flow.response.get_text()
    except Exception:
        return
    if "ineligibleTiers" not in body and "ineligible_tiers" not in body:
        return
    try:
        data = json.loads(body)
    except Exception:
        return
    changed = []
    def clean(obj):
        if isinstance(obj, dict):
            for k in list(obj.keys()):
                if k in ("ineligibleTiers", "ineligible_tiers"):
                    obj[k] = []
                    changed.append(k)
                else:
                    clean(obj[k])
        elif isinstance(obj, list):
            for v in obj:
                clean(v)
    clean(data)
    if changed:
        flow.response.set_text(json.dumps(data))
        _log(f"CLEANED {changed} in {flow.request.pretty_url}")
