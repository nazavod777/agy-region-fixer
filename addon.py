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

# verbose mode records the SHAPE of Google's JSON answers (field names and types) so a change in
# the API can be diagnosed without exposing tokens or personal data: values are never written,
# except for these keys, which hold enumerations and tier ids
SHAPE_VALUE_KEYS = ("reasonCode", "reason_code", "tierId", "tier_id")
SHAPE_MAX_DEPTH = 5
SHAPE_MAX_KEYS = 40
SHAPE_MAX_CHARS = 4000

def _shape(obj, key=None, depth=0):
    if depth > SHAPE_MAX_DEPTH:
        return "..."
    if isinstance(obj, dict):
        return {k: _shape(v, k, depth + 1) for k, v in list(obj.items())[:SHAPE_MAX_KEYS]}
    if isinstance(obj, list):
        return [_shape(obj[0], key, depth + 1), "x%d" % len(obj)] if obj else []
    if isinstance(obj, str):
        return obj[:80] if key in SHAPE_VALUE_KEYS else "str"
    return type(obj).__name__

def _log_shape(flow, body):
    url = flow.request.pretty_url.split("?")[0]
    head = "SHAPE %s %s %s" % (flow.request.method, url, flow.response.status_code)
    try:
        text = json.dumps(_shape(json.loads(body)), ensure_ascii=False)
    except Exception:
        text = "<not json, %d bytes, %s>" % (len(body), flow.response.headers.get("content-type", "?"))
    _log(head + " -> " + text[:SHAPE_MAX_CHARS])

def request(flow: http.HTTPFlow):
    # full-URL logging only in verbose mode (for debugging): create <prefix>/verbose.flag;
    # the flag is checked on every request, so it can be toggled without restarting the proxy
    if os.path.exists(VERBOSE_FLAG):
        _log(f"REQ {flow.request.method} {flow.request.pretty_url}")

def response(flow: http.HTTPFlow):
    # clean ONLY responses from Google domains; leave other sites alone
    if not flow.request.pretty_host.endswith(".googleapis.com"):
        return
    verbose = os.path.exists(VERBOSE_FLAG)
    try:
        body = flow.response.get_text()
    except Exception:
        if verbose:
            _log("SHAPE %s %s %s -> <undecodable body>" % (flow.request.method, flow.request.pretty_url.split("?")[0], flow.response.status_code))
        return
    if verbose:
        _log_shape(flow, body)
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
