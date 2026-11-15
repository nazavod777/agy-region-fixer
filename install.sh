#!/usr/bin/env bash
# ============================================================================
# agy-region-fixer — Antigravity CLI region bypass, one-shot installer
# Supports:  Linux (systemd: Ubuntu/Debian/Kali/Fedora/Arch/openSUSE/Alpine)
#            and macOS (launchd). For Windows, use install.ps1.
#
# What it does: installs a local MITM proxy (mitmproxy) that, in Google
# loadCodeAssist responses, strips the ineligibleTiers field — the CLI sees only
# allowedTiers and lets the user in. The agy binary is NOT patched or modified,
# so CLI updates break nothing; the shim heals itself
# (via a path unit/WatchPaths, plus a timer every 5 minutes)
# after a CLI update.
#
# Install:     curl -fsSL <url>/install.sh | bash        (macOS)
#              curl -fsSL <url>/install.sh | sudo bash   (Linux)
#              powershell -ExecutionPolicy Bypass -File install.ps1  (Windows)
# Uninstall:   bash  <prefix>/uninstall.sh   |  powershell <prefix>\uninstall.ps1
#
# Requires:    Python 3.12 or 3.13 (mitmproxy 12.x needs it; if the default
#              python3 is a different version, the installer finds python3.13/python3.12),
#              curl, and an installed, logged-in Antigravity CLI (`agy login`).
# Custom port: AGY_BYPASS_PORT=8081 bash install.sh
#
# The proxy addon lives in addon.py next to this script (in the repo); with a
# pipe install (curl | bash) it is downloaded from raw.githubusercontent.com
# (override: AGY_ADDON_URL=...).
# ============================================================================
set -euo pipefail
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
OWNER_PATH_FILE=""
trap '[[ -z "$OWNER_PATH_FILE" ]] || rm -f "$OWNER_PATH_FILE"' EXIT

OS="$(uname -s)"
AGY_PIN="mitmproxy==12.3.1"
RAW_BASE="https://raw.githubusercontent.com/nazavod777/agy-region-fixer/master"

say()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31mERR:\033[0m %s\n' "$*" >&2; exit 1; }

# --- platform paths ---------------------------------------------------------
if [[ "$OS" == "Darwin" ]]; then
  PREFIX="${AGY_BYPASS_PREFIX:-$HOME/.agy-region-fixer}"
  NEED_ROOT=0
elif [[ "$OS" == "Linux" ]]; then
  PREFIX="${AGY_BYPASS_PREFIX:-/opt/agy-region-fixer}"
  NEED_ROOT=1
else
  err "OS $OS is not supported by this script — on Windows use install.ps1"
fi
PORT="${AGY_BYPASS_PORT:-}"
if [[ -n "$PORT" ]]; then
  case "$PORT" in *[!0-9]*) err "AGY_BYPASS_PORT must be a decimal integer from 1 to 65535" ;; esac
  while [[ "$PORT" == 0* && ${#PORT} -gt 1 ]]; do PORT="${PORT#0}"; done
  [[ ${#PORT} -le 5 ]] && (( 10#$PORT >= 1 && 10#$PORT <= 65535 )) \
    || err "AGY_BYPASS_PORT must be a decimal integer from 1 to 65535"
  PORT="$((10#$PORT))"
fi
VENV="$PREFIX/venv"
CA_DIR="$PREFIX/ca"
# uninstall.sh removes PREFIX entirely — do not allow the root or the home directory
[[ "$PREFIX" == /* && "$PREFIX" != "/" && "$PREFIX" != "${HOME:-}" ]] \
  || err "AGY_BYPASS_PREFIX must be an absolute path, but not / and not \$HOME (uninstall removes the directory entirely)"
# \ " ' % $ and newline have special meaning in systemd unit files (ExecStart) — not supported
case "$PREFIX" in
  *[\\\"\'%\$]* | *$'\n'*) err "AGY_BYPASS_PREFIX must not contain the characters \\ \" ' % \$ or a newline" ;;
esac

# --- basic checks -----------------------------------------------------------
command -v curl >/dev/null || err "curl not found"
if [[ $NEED_ROOT -eq 1 ]]; then
  [[ $EUID -eq 0 ]] || err "on Linux run via sudo"
  command -v systemctl >/dev/null || err "systemd not found (containers/WSL1 are not supported)"
fi

# mitmproxy 12.x needs python >=3.12, <3.14 (on 3.14 pip silently installs a broken
# environment without pyparsing). The version alone is not enough: a Python built from
# source without dev headers lacks stdlib C modules, and mitmdump crashes at start
# ("No module named '_ctypes'"). Without these three it never starts (measured on
# mitmproxy 12.3.1); anything else is caught by checking the finished venv.
# an array, not a string: bash 3.2 applies a temporary IFS (see `IFS=$'\t' read` below)
# inside process substitution, so a word-split string would arrive as one argument
PY_REQUIRED_MODULES=(ctypes ssl zlib)
PY_DEV_HINT="Debian/Ubuntu: apt install python3.12 python3.12-venv; macOS: brew install python@3.12 (or xcode-select --install); a self-built Python needs libffi-dev libssl-dev zlib1g-dev before ./configure"

# prints "OK<TAB>realpath" if the interpreter fits, otherwise "NO<TAB>reason"
python_check() {
  "$1" - "${PY_REQUIRED_MODULES[@]}" 2>/dev/null <<'PYCHECK' || printf 'NO\tdoes not run\n'
import os, sys
v = sys.version_info
if not (3, 12) <= v[:2] < (3, 14):
    print("NO\tversion %d.%d.%d (need 3.12 or 3.13)" % v[:3]); sys.exit(0)
missing = []
for name in sys.argv[1:]:
    try:
        __import__(name)
    except Exception:
        missing.append(name)
if missing:
    print("NO\t%d.%d.%d without stdlib modules: %s" % (v[0], v[1], v[2], " ".join(missing)))
else:
    print("OK\t" + os.path.realpath(sys.executable))
PYCHECK
}

# every python3.13 / python3.12 / python3 on PATH (not only the first one: /usr/local
# often shadows a working distro build), deduplicated by the real interpreter
PY_CANDIDATES=()
PY_REJECTED=""
PY_SEEN=$'\n'
for PY_NAME in python3.13 python3.12 python3; do
  while IFS= read -r PY_PATH; do
    [[ -n "$PY_PATH" ]] || continue
    IFS=$'\t' read -r PY_STATUS PY_INFO < <(python_check "$PY_PATH") || PY_STATUS=""
    [[ -n "$PY_INFO" ]] || PY_INFO="printed nothing"
    if [[ "$PY_STATUS" == OK ]]; then
      [[ "$PY_SEEN" == *$'\n'"$PY_INFO"$'\n'* ]] && continue
      PY_SEEN="$PY_SEEN$PY_INFO"$'\n'
      PY_CANDIDATES+=("$PY_PATH")
    else
      PY_REJECTED="$PY_REJECTED  - $PY_PATH: $PY_INFO"$'\n'
    fi
  done < <(type -ap "$PY_NAME" 2>/dev/null || true)
done

# escape a string for XML (plist): & < > in paths must not break the file
xml_esc() { sed 's|&|\&amp;|g; s|<|\&lt;|g; s|>|\&gt;|g' <<<"$1"; }

# Run in a private session: interactive shells must not stop on the caller's terminal.
# The verified Python works on Linux and macOS without timeout/setsid dependencies.
run_with_timeout() {
  local secs="$1" timeout_pid rc=0; shift
  "$PYBIN" -I -c '
import os, signal, subprocess, sys, tempfile, time
cancelled = 0
def cancel(signum, frame):
    global cancelled
    if not cancelled: cancelled = signum
signal.signal(signal.SIGINT, cancel)
signal.signal(signal.SIGTERM, cancel)
signal.signal(signal.SIGHUP, cancel)
child = subprocess.Popen(sys.argv[2:], start_new_session=True)
deadline = time.monotonic() + float(sys.argv[1])
status = 124
def signal_session(sig):
    # Shell job control may split one session into several process groups.
    # Verify session membership before each signal; never target the caller session.
    def send(pid):
        try:
            if os.getsid(pid) == child.pid:
                os.kill(pid, sig)
        except (ProcessLookupError, PermissionError):
            pass
    if os.path.isdir("/proc/self"):
        with os.scandir("/proc") as entries:
            for entry in entries:
                if entry.name.isdecimal(): send(int(entry.name))
    else:
        # macOS has no /proc; its system ps provides a streamed PID listing.
        with tempfile.TemporaryFile() as listing:
            subprocess.run(["/bin/ps", "-A", "-o", "pid="], stdout=listing,
                           stderr=subprocess.DEVNULL, timeout=2, check=True)
            listing.seek(0)
            for line in listing: send(int(line))
try:
    while not cancelled:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            break
        try:
            status = child.wait(timeout=min(0.2, remaining))
            break
        except subprocess.TimeoutExpired:
            pass
finally:
    # Also close pipe-holding descendants after the leader exits. Stopped and
    # TERM-ignoring children must not defeat cancellation or the deadline.
    for sig in (signal.SIGTERM, signal.SIGCONT):
        signal_session(sig)
    try: child.wait(timeout=1)
    except subprocess.TimeoutExpired: pass
    signal_session(signal.SIGKILL)
    child.wait()
if cancelled:
    status = 128 + cancelled
elif status < 0:
    status = 128 - status
sys.exit(status)
' "$secs" "$@" &
  timeout_pid=$!
  # Waiting on our explicit child lets Bash process signals immediately, including
  # SIGTERM sent only to the installer rather than to the whole terminal group.
  trap 'trap "" INT TERM HUP; kill -INT "$timeout_pid" 2>/dev/null || true; wait "$timeout_pid" 2>/dev/null || true; exit 130' INT
  trap 'trap "" INT TERM HUP; kill -TERM "$timeout_pid" 2>/dev/null || true; wait "$timeout_pid" 2>/dev/null || true; exit 143' TERM
  trap 'trap "" INT TERM HUP; kill -HUP "$timeout_pid" 2>/dev/null || true; wait "$timeout_pid" 2>/dev/null || true; exit 129' HUP
  wait "$timeout_pid" || rc=$?
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP
  return "$rc"
}

# Keep the timed command in the main shell so its signal traps run immediately.
# Command substitutions defer the outer shell traps until the entire pipe closes.
capture_owner_path() {
  OWNER_PATH_FILE="$(mktemp)"
  run_with_timeout 15 "$@" </dev/null >"$OWNER_PATH_FILE" 2>/dev/null || true
  OWNER_PATH="$(sed -n 's/^@@AGYPATH@@\(.*\)@@$/\1/p' "$OWNER_PATH_FILE" | tail -n 1)"
  rm -f "$OWNER_PATH_FILE"
  OWNER_PATH_FILE=""
}

select_proxy_port() {
  "$PYBIN" -I -c '
import random, socket, sys
requested, previous, active = sys.argv[1:]
def usable(port):
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
        try: listener.bind(("127.0.0.1", port)); return True
        except OSError: return False
if requested:
    port = int(requested)
    if (active == "0" and previous == requested) or usable(port):
        print(port); sys.exit(0)
    sys.exit("Requested proxy port %s is busy; choose another AGY_BYPASS_PORT." % port)
previous = previous.lstrip("0")
if previous.isascii() and previous.isdecimal() and len(previous) <= 5 and 49152 <= int(previous) <= 65535:
    port = int(previous)
    if active == "0" or usable(port):
        print(port); sys.exit(0)
for attempt in range(32):
    port = random.SystemRandom().randint(49152, 65535)
    if usable(port):
        print(port); sys.exit(0)
sys.exit("No free localhost proxy port found in 49152-65535; set AGY_BYPASS_PORT.")
' "$PORT" "$OLD_PORT" "$SERVICE_ACTIVE"
}

# ---------------------------------------------------------------------------
say "1/6 Vendored venv + mitmproxy (pinned version, the system is left alone)"
mkdir -p "$PREFIX" "$CA_DIR"
# PYTHONPATH from the environment (CI, activated venvs, IDEs) poisons the venv:
# foreign packages of incompatible versions leak into it — clean it for all
# python/pip install operations
CLEAN_ENV=(env -u PYTHONPATH -u SSL_CERT_FILE -u HTTPS_PROXY -u https_proxy)
PY_LOG="$PREFIX/python-setup.log"   # venv/pip/mitmdump output; its tail is shown on failure
: > "$PY_LOG"
AGY_PIN_VERSION="${AGY_PIN#*==}"

# a working venv = mitmdump starts and reports the pinned version. This catches "pip said
# ok, but the environment is broken" (python 3.14 without pyparsing, missing stdlib
# modules, a foreign cryptography from PYTHONPATH) and an outdated pin
venv_works() {
  local out
  [[ -x "$VENV/bin/mitmdump" ]] || return 1
  out="$("${CLEAN_ENV[@]}" "$VENV/bin/mitmdump" --version 2>&1)" || { printf '%s\n' "$out" >> "$PY_LOG"; return 1; }
  # exact match of the "Mitmproxy: X.Y.Z" line: a substring would accept 12.3.10 for 12.3.1
  [[ "$(printf '%s\n' "$out" | awk '$1 == "Mitmproxy:" { print $2; exit }')" == "$AGY_PIN_VERSION" ]] \
    || { printf 'outdated: %s\n' "$out" >> "$PY_LOG"; return 1; }
}

# the distro splits the venv module into a separate package (Debian/Ubuntu: python3.X-venv)
install_venv_package() {
  local ver="$1"
  if   command -v apt-get >/dev/null; then apt-get update -qq && apt-get install -y -qq "python${ver}-venv" python3-pip
  elif command -v dnf     >/dev/null; then dnf install -y python3-pip
  elif command -v zypper  >/dev/null; then zypper --non-interactive install python3-pip
  elif command -v apk     >/dev/null; then apk add py3-virtualenv py3-pip
  else return 1
  fi
}

# builds the venv from scratch with interpreter $1; 0 only if mitmdump works in it
build_venv() {
  local py="$1" ver real
  ver="$("$py" -c 'import sys; print("%d.%d" % sys.version_info[:2])')"
  real="$("$py" -c 'import os, sys; print(os.path.realpath(sys.executable))')"
  rm -rf "$VENV"
  if ! "${CLEAN_ENV[@]}" "$py" -m venv "$VENV" >> "$PY_LOG" 2>&1; then
    rm -rf "$VENV"
    # a package manager only helps the distro's own interpreter, not a /usr/local build;
    # the real path, because merged-/usr systems also expose it as /bin/python3.X
    [[ "$real" == /usr/bin/* ]] || return 1
    say "python -m venv failed for $py — installing the venv package with the package manager"
    install_venv_package "$ver" >> "$PY_LOG" 2>&1 || return 1
    "${CLEAN_ENV[@]}" "$py" -m venv "$VENV" >> "$PY_LOG" 2>&1 || return 1
  fi
  "${CLEAN_ENV[@]}" "$VENV/bin/pip" install --quiet --upgrade pip >> "$PY_LOG" 2>&1 || return 1
  "${CLEAN_ENV[@]}" "$VENV/bin/pip" install --quiet "$AGY_PIN" >> "$PY_LOG" 2>&1 || return 1
  venv_works
}

if venv_works; then
  say "venv with mitmproxy $AGY_PIN_VERSION is already in place — reusing it"
else
  # a venv left by a failed or older install is rebuilt: otherwise every re-run
  # would hit the same broken environment. It is set aside, not deleted, until the new
  # one works: an outdated but working venv must survive a failed rebuild (no network)
  VENV_PREV="$VENV.prev"
  rm -rf "$VENV_PREV"
  if [[ -e "$VENV" ]]; then
    say "the existing venv is broken or outdated — rebuilding it"
    mv "$VENV" "$VENV_PREV"
  fi
  if [[ -n "$PY_REJECTED" ]]; then
    say "skipped interpreters:"; printf '%s' "$PY_REJECTED"
  fi
  VENV_OK=0
  for PY_PATH in ${PY_CANDIDATES[@]+"${PY_CANDIDATES[@]}"}; do
    say "python: $PY_PATH ($("$PY_PATH" --version 2>&1))"
    if build_venv "$PY_PATH"; then VENV_OK=1; break; fi
    say "⚠️  mitmproxy does not work with $PY_PATH — trying the next interpreter"
    PY_REJECTED="$PY_REJECTED  - $PY_PATH: venv/mitmproxy setup failed"$'\n'
  done
  if [[ $VENV_OK -ne 1 ]]; then
    rm -rf "$VENV"
    # same path as before, so the old venv's scripts keep working after the move back
    [[ ! -e "$VENV_PREV" ]] || { mv "$VENV_PREV" "$VENV"; say "the previous venv is put back unchanged"; }
    {
      if [[ ${#PY_CANDIDATES[@]} -eq 0 ]]; then
        echo "no usable Python 3.12/3.13 found:"
        if [[ -n "$PY_REJECTED" ]]; then printf '%s' "$PY_REJECTED"
        else echo "  - no python3.13 / python3.12 / python3 on PATH"; fi
      else
        echo "a suitable Python was found, but venv/pip could not set up mitmproxy $AGY_PIN_VERSION:"
        printf '%s' "$PY_REJECTED"
      fi
      if [[ -s "$PY_LOG" ]]; then echo "last lines of $PY_LOG:"; tail -n 8 "$PY_LOG"; fi
    } >&2
    if [[ ${#PY_CANDIDATES[@]} -eq 0 ]]; then
      err "install a complete Python 3.12/3.13 — $PY_DEV_HINT"
    fi
    err "check the network and access to pypi.org (the log above has pip's error), then re-run"
  fi
  rm -rf "$VENV_PREV"
fi
PYBIN="$VENV/bin/python"   # a verified interpreter for the remaining install steps

# ---------------------------------------------------------------------------
say "2/6 Addon: strips ineligibleTiers from Google responses"
# addon.py is the single source of truth (in the repo next to install.sh);
# with a pipe install it is not next to the script — download it from raw.githubusercontent
SCRIPT_DIR=""
[[ -n "${BASH_SOURCE[0]:-}" ]] && SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || true)"
if [[ -n "${SCRIPT_DIR:-}" && -f "$SCRIPT_DIR/addon.py" && -f "$SCRIPT_DIR/install.sh" ]]; then
  ADDON_SRC="$SCRIPT_DIR/addon.py"
else
  ADDON_SRC="$PREFIX/addon.py.tmpl"
  curl -fsSL "$RAW_BASE/addon.py" -o "$ADDON_SRC" \
    || err "failed to download addon.py ($RAW_BASE/addon.py)"
fi
# placeholders are substituted by python as string literals (json.dumps): paths with
# quotes, backslashes and sed metacharacters do not break the addon
install_addon_source() {
  "${CLEAN_ENV[@]}" "$PYBIN" -I -c '
import json, sys
src, dst, log, flag = sys.argv[1:5]
def literal(value):
    return json.dumps(value, ensure_ascii=False)[1:-1]
with open(src, encoding="utf-8") as f:
    text = f.read()
text = text.replace("@@LOG@@", literal(log)).replace("@@VERBOSE_FLAG@@", literal(flag))
with open(dst, "w", encoding="utf-8", newline="") as f:
    f.write(text)
' "$1" "$2" "$PREFIX/mitm.log" "$PREFIX/verbose.flag"
  if grep -q '@@LOG@@\|@@VERBOSE_FLAG@@' "$2"; then
    err "unsubstituted placeholders left in $2"
  fi
  "${CLEAN_ENV[@]}" "$PYBIN" -I -c 'import sys; compile(open(sys.argv[1], encoding="utf-8").read(), sys.argv[1], "exec")' "$2" \
    || err "the generated $2 does not compile"
}
install_addon_source "$ADDON_SRC" "$PREFIX/addon.py"
[[ "$ADDON_SRC" == "$PREFIX/addon.py.tmpl" ]] && rm -f "$ADDON_SRC"
CUSTOM_EXEC_ARGS=""; CUSTOM_PLIST_ARGS=""
if [[ -n "${AGY_ADDON_URL:-}" ]]; then
  # Keep the existing hook-only custom addon contract: the default addon owns
  # startup and loads the custom module once, without mitmdump's script watcher.
  CUSTOM_SOURCE="$PREFIX/custom-addon.py.tmpl"
  curl -fsSL "$AGY_ADDON_URL" -o "$CUSTOM_SOURCE" \
    || err "failed to download the custom addon ($AGY_ADDON_URL)"
  install_addon_source "$CUSTOM_SOURCE" "$PREFIX/custom-addon.py"
  rm -f "$CUSTOM_SOURCE"
  CUSTOM_EXEC_ARGS=" --addon \"$PREFIX/custom-addon.py\""
  CUSTOM_PLIST_ARGS="    <string>--addon</string><string>$(xml_esc "$PREFIX/custom-addon.py")</string>"
fi

# ---------------------------------------------------------------------------
say "3/6 Proxy autostart (selecting a localhost port)"
# Reuse only an active service's recorded high port; fresh installs and busy stale
# ports use a random bindable port. An explicit override never silently changes.
OLD_PORT="$(head -c 64 "$PREFIX/port" 2>/dev/null || true)"
if [[ "$OS" == "Linux" ]]; then
  SERVICE_ACTIVE=1; systemctl is-active --quiet agy-region-fixer.service && SERVICE_ACTIVE=0
  PORT="$(select_proxy_port)" || err "could not select the proxy port"
  say "Proxy address: 127.0.0.1:$PORT"
  cat > /etc/systemd/system/agy-region-fixer.service <<UNIT
[Unit]
Description=Antigravity region fixer (MITM, cleans ineligibleTiers)
After=network-online.target

[Service]
ExecStart="$VENV/bin/python" -I "$PREFIX/addon.py" --port $PORT --confdir "$CA_DIR"$CUSTOM_EXEC_ARGS
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl restart agy-region-fixer.service   # unit/addon may have changed — reload
  systemctl enable agy-region-fixer.service >/dev/null 2>&1
else  # macOS: LaunchAgent for the current user
  # exact label match: "com.agy.region-fixer" is not a prefix of the heal agent
  SERVICE_ACTIVE=1; launchctl list 2>/dev/null | awk '$3 == "com.agy.region-fixer" { found = 1 } END { exit !found }' && SERVICE_ACTIVE=0
  PORT="$(select_proxy_port)" || err "could not select the proxy port"
  say "Proxy address: 127.0.0.1:$PORT"
  PLIST="$HOME/Library/LaunchAgents/com.agy.region-fixer.plist"
  mkdir -p "$HOME/Library/LaunchAgents"
  X_VENV="$(xml_esc "$VENV")"; X_PREFIX="$(xml_esc "$PREFIX")"; X_CA_DIR="$(xml_esc "$CA_DIR")"
  cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.agy.region-fixer</string>
  <key>ProgramArguments</key><array>
    <string>$X_VENV/bin/python</string>
    <string>-I</string><string>$X_PREFIX/addon.py</string>
    <string>--port</string><string>$PORT</string>
    <string>--confdir</string><string>$X_CA_DIR</string>
$CUSTOM_PLIST_ARGS
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$X_PREFIX/launchd.out</string>
  <key>StandardErrorPath</key><string>$X_PREFIX/launchd.err</string>
</dict></plist>
PLISTEOF
  launchctl bootout "gui/$(id -u)" "$PLIST" >/dev/null 2>&1 || true
  launchctl bootstrap "gui/$(id -u)" "$PLIST" || launchctl load -w "$PLIST"
fi
printf '%s\n' "$PORT" > "$PREFIX/port"   # which port our service sits on (checked on reinstall)

# wait for the CA and for the proxy to be ready
for _ in $(seq 1 30); do
  [[ -f "$CA_DIR/mitmproxy-ca-cert.pem" ]] && break
  sleep 1
done
[[ -f "$CA_DIR/mitmproxy-ca-cert.pem" ]] || err "CA was not generated (did the service die? journalctl -u agy-region-fixer / $PREFIX/launchd.err)"
MITM_OK=0
for _ in $(seq 1 20); do
  if curl -s --max-time 5 --cacert "$CA_DIR/mitmproxy-ca-cert.pem" \
    -x "http://127.0.0.1:$PORT" -o /dev/null https://www.google.com/; then
    MITM_OK=1; break
  fi
  sleep 1
done
if [[ $MITM_OK -eq 1 ]]; then
  say "proxy is alive, MITM works"
else
  say "⚠️  MITM check did not pass within 20 s — check the log (journalctl -u agy-region-fixer / $PREFIX/launchd.err)"
fi

# ---------------------------------------------------------------------------
say "4/6 Shim for agy (env SSL_CERT_FILE + HTTPS_PROXY, with fallback)"
# common.sh — functions shared by install.sh / heal.sh (single source: symlink
# resolution, our-shim detector, shim generation, lock, privilege drop).
# Values are inserted via printf %q — paths with spaces and metacharacters are safe.
#
# SECURITY MODEL (Linux): heal runs as root (systemd), while the directory holding agy
# usually belongs to the user. Any file operation in such a directory
# (mv, writing the shim, chown) done as root is a write through paths the
# user controls (a planted link, a race on a temp file). So root only
# takes the lock and writes the log, while the work on the binary is done as its owner
# (runuser/setpriv): nothing happens above the owner's own rights. If only root can write
# to the needed directory, while the agy path lies in a directory the user controls —
# the action is refused rather than performed as root.
chmod 755 "$PREFIX"
{
  printf '# agy-region-fixer: shared functions (generated by install.sh)\nPREFIX_SH=%q\nPORT_SH=%q\nCA_SH=%q\n' \
    "$PREFIX" "$PORT" "$CA_DIR"
  cat <<'COMMONEOF'
SHIM_MARKER="agy-region-fixer-shim"
MIN_REAL_BYTES=10000000   # a real agy is ≥10 MB; smaller — an unfinished update/garbage
LOCK_WAIT_SECONDS=120
HEAL_QUIET_SECONDS=0.5    # active-event coalescing; no resident polling loop
HEAL_WAIT_SECONDS=30      # total readiness and staging deadline per entry
HEAL_MISSING_SECONDS=2   # allow delete-then-rename updates before manual/timer recovery
HEAL_EVENT=0

# is this our shim: marker in the first 256 bytes (we do not read the whole binary)
is_our_shim() { head -c 256 "$1" 2>/dev/null | grep -aq "$SHIM_MARKER"; }

# resolve symlinks (brew/npm install agy as a link to a binary buried deeper): the shim
# must sit next to the REAL binary, otherwise exec via $0 breaks
resolve_link() {
  local p="$1" t i=0
  while [[ -L "$p" && $i -lt 20 ]]; do
    t="$(readlink "$p")"
    if [[ "$t" = /* ]]; then p="$t"; else p="$(cd "$(dirname "$p")" && pwd)/$t"; fi
    i=$((i+1))
  done
  # Normalize ../ and symlinked directories even when an updater temporarily
  # removed the binary. The physical parent still identifies the same target.
  # If the parent itself vanished, leave the path for the next event/timer.
  if [[ -d "$(dirname "$p")" ]]; then
    p="$(cd -P "$(dirname "$p")" && pwd -P)/$(basename "$p")"
  fi
  printf '%s\n' "$p"
}

# string in single quotes for POSIX sh (locale-independent, unlike printf %q:
# in the C locale it emits $'\320..', which dash does not understand)
sh_quote() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

# shim text for the real binary $1 (absolute path, safe to invoke via a symlink);
# $2 — directory with the CA certificate as the CLI sees it (default: the prefix's own)
render_shim() {
  printf '%s\n' '#!/bin/sh' "# $SHIM_MARKER"
  printf 'PORT=%s\nCA_DIR=%s\nREAL=%s\n' "$(sh_quote "$PORT_SH")" "$(sh_quote "${2:-$CA_SH}")" "$(sh_quote "$1")"
  cat <<'SHIMBODY'
if curl -s --noproxy '*' -o /dev/null --max-time 2 "http://127.0.0.1:$PORT/"; then
  export SSL_CERT_FILE="$CA_DIR/mitmproxy-ca-cert.pem"
  export HTTPS_PROXY="http://127.0.0.1:$PORT"
fi
exec "$REAL" "$@"
SHIMBODY
}

# Keep temporary shim writes outside the directly watched parent. A failed
# refresh or launcher repair must not continually trigger another failed repair.
shim_stage_directory() {
  "$PREFIX_SH/venv/bin/python" -I - "$1" <<'STAGEEOF'
import os
import stat
import sys

stage = os.path.join(os.path.dirname(sys.argv[1]), ".agy-region-fixer-stage")
try:
    try:
        os.mkdir(stage, 0o700)
    except FileExistsError:
        pass
    info = os.stat(stage, follow_symlinks=False)
    if (not stat.S_ISDIR(info.st_mode) or info.st_uid != os.geteuid()
            or stat.S_IMODE(info.st_mode) != 0o700):
        raise PermissionError("staging directory must be owned by the worker with mode 0700")
except OSError as error:
    print("[heal] Blocked: cannot prepare %s: %s" % (stage, error), file=sys.stderr)
    sys.exit(1)
print(stage)
STAGEEOF
}

# Atomic shim publication: O_EXCL temporary file + chmod 755 before mv.
# Runs with the directory owner's rights (see the security model).
write_shim() {
  local real="$1" dst="$2" ca_dir="${3:-}" tmp stage
  stage="$(shim_stage_directory "$dst")" || return 1
  tmp="$(mktemp "$stage/$(basename "$dst").shim.XXXXXX")" || return 1
  if render_shim "$real" "$ca_dir" > "$tmp" && chmod 755 "$tmp" && mv -f "$tmp" "$dst"; then
    return 0
  fi
  rm -f "$tmp"
  return 1
}

# --- privilege drop (Linux/root only) ---------------------------------------
# unprivileged owner of the binary; empty — no drop needed
owner_user() {
  local o
  [[ $EUID -eq 0 ]] || return 0
  o="$(cat "$PREFIX_SH/owner" 2>/dev/null || true)"
  [[ -n "$o" && "$o" != root ]] && id -u "$o" >/dev/null 2>&1 && printf '%s\n' "$o"
  return 0
}
can_drop_privileges() { command -v runuser >/dev/null 2>&1 || command -v setpriv >/dev/null 2>&1; }
drop_to_owner() {
  local o; o="$(owner_user)"
  if command -v runuser >/dev/null 2>&1; then
    runuser -u "$o" -- "$@"
  else
    setpriv --reuid="$o" --regid="$(id -g "$o")" --init-groups -- "$@"
  fi
}
owner_can_write() { drop_to_owner test -w "$1" 2>/dev/null; }

# on whose behalf to handle agy entry $1, whose resolved path is $2: self | owner | refuse
#  self   — no drop needed (not root / owner is root)
#  owner  — the owner can write to the target's directory: work as the owner
#  refuse — only root can write to the target's directory, but the agy path lies in a directory
#           controlled by the owner (a link to a system file) — refuse
#  self   — also when both directories are controlled by root only (agy in /usr/local/bin)
entry_mode() {
  local entry="$1" target="$2"
  if [[ -z "$(owner_user)" ]]; then echo self; return; fi
  if ! can_drop_privileges; then echo refuse; return; fi
  if owner_can_write "$(dirname "$target")"; then echo owner; return; fi
  if owner_can_write "$(dirname "$entry")"; then echo refuse; return; fi
  echo self
}

# --- launchers: entries that must NOT be replaced in place -----------------
# snap: /snap/bin/agy -> antigravity-cli -> /usr/bin/snap (-> snapd itself); renaming that would
# break snapd, and the snap is read-only anyway. Nix store paths are read-only as well.
# For these the shim is a WRAPPER placed earlier in the user's PATH; the launcher stays untouched.
is_launcher() {   # $1 = resolved target
  case "$1" in
    /snap/*|/usr/lib/snapd/*|/var/lib/snapd/*|/usr/bin/snap|/nix/store/*) return 0 ;;
  esac
  case "${1##*/}" in snap|snapd) return 0 ;; esac
  return 1
}

# wrappers.path (written by install.sh, root-owned): entry <TAB> wrapper <TAB> ca_dir
WRAPPERS_FILE="$PREFIX_SH/wrappers.path"
wrapper_field() {   # $1 entry, $2 field number (2 = wrapper path, 3 = CA dir)
  [[ -f "$WRAPPERS_FILE" ]] || return 0
  awk -F'\t' -v e="$1" -v n="$2" '$1 == e { print $n; exit }' "$WRAPPERS_FILE"
}

# (re)create the wrapper for launcher $1. Idempotent: nothing is written when it is already
# current, so a heal run triggered by our own write cannot loop
wrap_entry() {
  local entry="$1" force="$2" wrapper ca_dir tmp ca_src="$CA_SH/mitmproxy-ca-cert.pem"
  wrapper="$(wrapper_field "$entry" 2)"; ca_dir="$(wrapper_field "$entry" 3)"
  [[ -n "$wrapper" ]] || { echo "[heal] $entry is a launcher (snap/nix) and no wrapper is registered — rerun the installer"; return 1; }
  [[ -e "$entry" ]] || return 0   # the application was removed: nothing to wrap
  if [[ -L "$wrapper" ]] || { [[ -e "$wrapper" ]] && ! is_our_shim "$wrapper"; }; then
    echo "[heal] $wrapper is not our wrapper — left as is"; return 0
  fi
  if [[ -n "$ca_dir" && "$ca_dir" != "$CA_SH" ]]; then
    # the CA must sit where the confined app may read it (snap: ~/snap/<name>/common)
    mkdir -p "$ca_dir" || { echo "[heal] FAILED to create $ca_dir"; return 1; }
    if ! cmp -s "$ca_src" "$ca_dir/mitmproxy-ca-cert.pem" 2>/dev/null; then
      tmp="$(mktemp "$ca_dir/.ca.XXXXXX")" || return 1
      if cp "$ca_src" "$tmp" && chmod 644 "$tmp" && mv -f "$tmp" "$ca_dir/mitmproxy-ca-cert.pem"; then :
      else rm -f "$tmp"; echo "[heal] FAILED to copy the CA to $ca_dir"; return 1; fi
    fi
  fi
  if [[ -f "$wrapper" ]] && [[ "$(cat "$wrapper")" == "$(render_shim "$entry" "$ca_dir")" ]]; then
    [[ "$force" -ne 1 ]] || echo "[heal] wrapper is up to date: $wrapper -> $entry"
    return 0
  fi
  write_shim "$entry" "$wrapper" "$ca_dir" || { echo "[heal] FAILED to write the wrapper $wrapper"; return 1; }
  if [[ "$force" -eq 1 ]]; then echo "[heal] wrapper installed: $wrapper -> $entry (the launcher is untouched)"
  else echo "[heal] restored the wrapper $wrapper"; fi
}

# uninstall: remove our wrapper and the CA copy; the launcher was never modified
unwrap_entry() {
  local entry="$1" wrapper ca_dir other_entry other_wrapper other_ca
  wrapper="$(wrapper_field "$entry" 2)"; ca_dir="$(wrapper_field "$entry" 3)"
  [[ -n "$wrapper" ]] || return 0
  if [[ -f "$wrapper" && ! -L "$wrapper" ]] && is_our_shim "$wrapper"; then
    rm -f "$wrapper" && echo "removed wrapper: $wrapper"
    rmdir "$(dirname "$wrapper")/.agy-region-fixer-stage" 2>/dev/null || true
  fi
  if [[ -n "$ca_dir" && "$ca_dir" != "$CA_SH" ]]; then
    # Snap aliases share a CA directory. Keep it while another installed wrapper
    # still uses it; the final wrapper removed during uninstall cleans it up.
    while IFS=$'\t' read -r other_entry other_wrapper other_ca; do
      [[ "$other_entry" != "$entry" && "$other_ca" == "$ca_dir" ]] || continue
      if [[ -f "$other_wrapper" ]] && is_our_shim "$other_wrapper"; then return 0; fi
    done < "$WRAPPERS_FILE"
    rm -f "$ca_dir/mitmproxy-ca-cert.pem"; rmdir "$ca_dir" 2>/dev/null || true
  fi
}

# Stage a replacement without moving the updater's file into .real. Readiness is
# evidence of a quiet file, not proof that an arbitrary updater has committed its
# transaction. A changed candidate is left Pending for another event/timer run.
repair_binary() {
  local entry="$1" target="$2" force="$3" shim_text
  shim_text="$(render_shim "$target.real")" || return 1
  "$PREFIX_SH/venv/bin/python" -I - "$entry" "$target" "$shim_text" "$force" \
    "$MIN_REAL_BYTES" "$HEAL_QUIET_SECONDS" "$HEAL_WAIT_SECONDS" \
    "$HEAL_MISSING_SECONDS" "$HEAL_EVENT" <<'REPAIREOF'
import json
import os
import signal
import stat
import sys
import tempfile
import time

entry, target, shim_text = sys.argv[1:4]
force, minimum = map(int, sys.argv[4:6])
quiet, wait, missing_grace = map(float, sys.argv[6:9])
event = bool(int(sys.argv[9]))
real = target + ".real"
deadline = time.monotonic() + wait
staged = backup = shim = None
published = False
failed = False
stage_safe = False
stage_dir = os.path.join(os.path.dirname(target), ".agy-region-fixer-stage")
blocked_path = os.path.join(stage_dir, os.path.basename(target) + ".blocked.json")


def cancel(signum, frame):
    raise SystemExit(128 + signum)


for signum in (signal.SIGTERM, signal.SIGHUP):
    signal.signal(signum, cancel)


def signature(info):
    return (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns)


def metadata(path):
    try:
        return os.stat(path, follow_symlinks=False)
    except FileNotFoundError:
        return None


def current(expected):
    info = metadata(target)
    return (os.path.realpath(entry) == os.path.abspath(target)
            and (signature(info) if info else None) == expected)


def pending(reason):
    print("[heal] Pending: %s — %s; retry on the next event or timer" % (target, reason))


def temporary(suffix):
    descriptor, path = tempfile.mkstemp(prefix=os.path.basename(target) + suffix,
                                        dir=stage_dir)
    return descriptor, path


def failure_state():
    return [list(signature(info)) if info is not None else None
            for info in (metadata(target), metadata(real))]


def repair():
    global staged, backup, shim, published, stage_safe
    previous = object()
    stable_since = missing_since = time.monotonic()
    expected = None
    while True:
        now = time.monotonic()
        info = metadata(target)
        state = signature(info) if info else None
        if (os.path.realpath(entry) != os.path.abspath(target)
                or (info is not None and stat.S_ISLNK(info.st_mode))):
            pending("entry changed or became a symlink")
            return
        if info and (not stat.S_ISREG(info.st_mode) or not info.st_mode & 0o111):
            raise PermissionError("candidate is not a regular executable")
        if info and info.st_mode & (stat.S_ISUID | stat.S_ISGID):
            raise PermissionError("candidate has setuid/setgid bits; refusing a privileged copy")
        if state != previous:
            previous, stable_since = state, now
            if info is None:
                missing_since = now
        if info is None:
            if now - missing_since >= missing_grace:
                if event:
                    pending("target is missing during an update")
                    return
                old = metadata(real)
                if old is None or not stat.S_ISREG(old.st_mode) or not old.st_mode & 0o111:
                    print("[heal] Blocked: no regular executable to restore at %s" % real)
                    return
                expected = None
                break
        elif force or now - stable_since >= quiet:
            if not force and info.st_size < minimum:
                pending("candidate is smaller than %s bytes" % minimum)
                return
            expected = state
            break
        if now >= deadline:
            pending("readiness deadline expired while the target was changing")
            return
        time.sleep(min(0.1, max(0, deadline - now)))

    old = metadata(real)
    if old is not None and not stat.S_ISREG(old.st_mode):
        print("[heal] Blocked: %s is not a regular file" % real)
        return
    # Parent path observers see one creation, but no staged-file churn inside
    # this private directory. A failed candidate must not trigger itself forever.
    try:
        os.mkdir(stage_dir, 0o700)
    except FileExistsError:
        pass
    directory = os.stat(stage_dir, follow_symlinks=False)
    if (not stat.S_ISDIR(directory.st_mode) or directory.st_uid != os.geteuid()
            or stat.S_IMODE(directory.st_mode) != 0o700):
        print("[heal] Blocked: unsafe staging directory %s" % stage_dir)
        return
    stage_safe = True
    if event and not force:
        try:
            with open(blocked_path, encoding="utf-8") as blocked:
                if json.load(blocked) == failure_state():
                    print("[heal] Blocked: %s is unchanged after a failed repair; timer/manual retry" % target)
                    return
        except (FileNotFoundError, ValueError):
            pass
    descriptor, shim = temporary(".shim.")
    with os.fdopen(descriptor, "wb") as destination:
        destination.write((shim_text + "\n").encode("utf-8"))
        destination.flush()
        os.fchmod(destination.fileno(), 0o755)
        os.fsync(destination.fileno())
    if expected is not None:
        descriptor = os.open(target, os.O_RDONLY | os.O_NOFOLLOW)
        with os.fdopen(descriptor, "rb") as source:
            if signature(os.fstat(source.fileno())) != expected:
                pending("candidate changed before staging")
                return
            descriptor, staged = temporary(".candidate.")
            with os.fdopen(descriptor, "wb") as destination:
                while True:
                    if time.monotonic() >= deadline:
                        pending("staging deadline expired")
                        return
                    block = source.read(1024 * 1024)
                    if not block:
                        break
                    destination.write(block)
                destination.flush()
                # A root worker may read a user-owned candidate in a root-only
                # directory. Copying must not promote its owner/group to root.
                if os.geteuid() == 0:
                    os.fchown(destination.fileno(), info.st_uid, info.st_gid)
                os.fchmod(destination.fileno(), stat.S_IMODE(info.st_mode))
                os.fsync(destination.fileno())
            if signature(os.fstat(source.fileno())) != expected or not current(expected):
                pending("candidate changed while staging")
                return
        old = metadata(real)
        if old is not None:
            if not stat.S_ISREG(old.st_mode):
                print("[heal] Blocked: %s is not a regular file" % real)
                return
            descriptor, backup = temporary(".previous.")
            os.close(descriptor)
            os.unlink(backup)
            os.link(real, backup, follow_symlinks=False)
            if signature(os.stat(backup, follow_symlinks=False))[:3] != signature(old)[:3]:
                pending("previous original changed before staging")
                return
        if not current(expected):
            pending("candidate changed before replacement")
            return
        published = True
        os.replace(staged, real)
        staged = None
    if not current(expected):
        pending("target changed before shim publication")
        return
    os.replace(shim, target)
    # The new original and shim are both in place; the previous original can go.
    published = False
    try:
        os.unlink(blocked_path)
    except FileNotFoundError:
        pass
    print("[heal] %s: %s" % ("shim installed" if force else "restored", target))


try:
    repair()
except OSError as error:
    failed = True
    print("[heal] Blocked: cannot repair %s: %s" % (target, error), file=sys.stderr)
    sys.exit(1)
finally:
    if published:
        # Shim publication failed or a concurrent update won the final check.
        # Preserve the old original; the updater's target has not been moved.
        try:
            if backup is not None:
                os.replace(backup, real)
            elif metadata(real) is not None:
                os.unlink(real)
        except OSError as error:
            print("[heal] Blocked: cannot restore previous original %s: %s" % (real, error),
                  file=sys.stderr)
            failed = True
            if backup is not None:
                print("[heal] Blocked: previous original retained at %s" % backup, file=sys.stderr)
            # Keep the backup for manual recovery if rollback itself failed.
            backup = None
    for path in (staged, backup, shim):
        if path is not None:
            try:
                os.unlink(path)
            except FileNotFoundError:
                pass
    if failed and stage_safe:
        # Cache only hard failures, inside the unwatched staging directory.
        # Our .real publication/rollback events must not perpetually retry the
        # same blocked target. A changed candidate or the fallback can retry.
        record = None
        try:
            descriptor, record = temporary(".blocked.")
            with os.fdopen(descriptor, "w", encoding="utf-8") as output:
                json.dump(failure_state(), output)
            os.replace(record, blocked_path)
            record = None
        except OSError as error:
            print("[heal] Blocked: cannot record failed candidate %s: %s" % (target, error),
                  file=sys.stderr)
        finally:
            if record is not None:
                os.unlink(record)
REPAIREOF
}

# --- working operations on a single shim.path entry (print log lines) -------
# $1 — shim.path entry, $2 — force: 1 on install (no minimum-size check)
shim_entry() {
  local entry="$1" force="$2" target
  target="$(resolve_link "$entry")"
  if [[ -n "$(wrapper_field "$entry" 2)" ]] || is_launcher "$target"; then
    wrap_entry "$entry" "$force"; return
  fi
  [[ -e "$target" || -e "$target.real" ]] || return 0
  if is_our_shim "$target"; then
    if [[ "$force" -eq 1 ]] || ! cmp -s "$target" <(render_shim "$target.real"); then
      write_shim "$target.real" "$target" || { echo "[heal] FAILED to update shim for $target"; return 1; }
      echo "[heal] shim updated: $target"
    fi
    return 0
  fi
  repair_binary "$entry" "$target" "$force"
}

# put the real binary back (uninstall). We restore the binary even when agy has vanished
# (interrupted update/heal): otherwise it would stay only under the name agy.real. If
# something foreign sits in agy's place — we leave it alone
restore_entry() {
  local target stage; target="$(resolve_link "$1")"
  if [[ -n "$(wrapper_field "$1" 2)" ]] || is_launcher "$target"; then
    unwrap_entry "$1"; return
  fi
  [[ -f "$target.real" ]] || return 0
  if [[ ! -e "$target" ]] || is_our_shim "$target"; then
    mv -f "$target.real" "$target" || { echo "FAILED to restore $target"; return 1; }
    echo "restored: $target"
    stage="$(dirname "$target")/.agy-region-fixer-stage"
    if [[ -d "$stage" && ! -L "$stage" && -O "$stage" ]]; then
      rm -f "$stage/$(basename "$target").blocked.json"
      rmdir "$stage" 2>/dev/null || true
    fi
  else
    echo "left as is: $target is not our shim; the previous binary is in $target.real"
  fi
}

# --- lock: two simultaneous heals would both see "not a shim", and the second would hide the
# first one's shim in agy.real — the real binary would be lost. Runs "$@" under the lock;
# code 75 — the lock was not acquired within LOCK_WAIT_SECONDS. The lock is held by a child process and
# released by the kernel when it exits in any way (SIGKILL/power loss — no "dead" locks)
with_heal_lock() {
  local lock="$PREFIX_SH/heal.lock" waited=0 holder rc
  if command -v flock >/dev/null 2>&1; then
    flock -w "$LOCK_WAIT_SECONDS" -E 75 "$lock" "$@"; return
  fi
  if command -v perl >/dev/null 2>&1; then   # macOS: no flock(1), but perl is there
    perl -e 'use Fcntl qw(:flock); $^F = 255; my ($f, $w, @c) = @ARGV;
             open(my $fh, ">>", $f) or exit 75; my $t = time + $w;
             until (flock($fh, LOCK_EX | LOCK_NB)) { exit 75 if time >= $t; select(undef, undef, undef, 0.2) }
             exec @c or exit 127;' "$lock" "$LOCK_WAIT_SECONDS" "$@"
    return
  fi
  # last resort — a mkdir lock (without flock and perl)
  while ! mkdir "$lock.d" 2>/dev/null; do
    holder="$(cat "$lock.d/pid" 2>/dev/null || true)"
    if [[ -n "$holder" ]] && ! ps -p "$holder" >/dev/null 2>&1; then
      mv "$lock.d" "$lock.d.stale.$$" 2>/dev/null && rm -rf "$lock.d.stale.$$"
      continue
    fi
    (( waited < LOCK_WAIT_SECONDS )) || return 75
    sleep 1; waited=$((waited+1))
  done
  echo "$$" > "$lock.d/pid"
  "$@"; rc=$?
  rm -rf "$lock.d"
  return "$rc"
}
COMMONEOF
} > "$PREFIX/common.sh"
chmod 644 "$PREFIX/common.sh"
# shellcheck source=/dev/null
. "$PREFIX/common.sh"

# heal.sh: if a CLI update overwrote the shim — restores it.
# Modes: (no arguments) — repair all shim.path entries; --place ENTRY — install
# or update the shim (install.sh); --restore — put the real binaries back (uninstall.sh).
# Heal triggers: systemd PathChanged (Linux), launchd WatchPaths (macOS),
# a timer every 5 minutes (safety net, all OSes) and a manual run. --event
# defers missing in-place targets; the timer/manual mode can recover a vanished shim.
{
  printf '#!/bin/bash\nSELF=%q\n. %q\n' "$PREFIX/heal.sh" "$PREFIX/common.sh"
  cat <<'HEALEOF'
ACTION=heal; ENTRY=""
case "${1:-}" in
  --event) HEAL_EVENT=1 ;;
  --place)   ACTION=place;   ENTRY="${2:?}" ;;
  --restore-entry) ACTION=restore-one; ENTRY="${2:?}" ;;
  --restore) ACTION=restore ;;
  --worker)  ACTION="worker:${2:?}"; ENTRY="${3:-}" ;;   # internal: work as the owner
esac

run_worker() {   # $1 = heal|place|restore, $2 = entry
  case "$1" in
    heal)    shim_entry "$2" 0 ;;
    event)   HEAL_EVENT=1; shim_entry "$2" 0 ;;
    place)   shim_entry "$2" 1 ;;
    restore) restore_entry "$2" ;;
  esac
}

if [[ "$ACTION" == worker:* ]]; then
  run_worker "${ACTION#worker:}" "$ENTRY"; exit $?
fi

# --- layer under the lock ---
run_entry() {   # $1 = heal|place|restore, $2 = entry; prints the log, returns the operation's code
  local action="$1" entry="$2" target mode out rc wrapper
  target="$(resolve_link "$entry")"
  wrapper="$(wrapper_field "$entry" 2)"
  if [[ -n "$wrapper" ]]; then
    # Wrapper paths and their parents belong to the user and can become symlinks.
    # Never fall back to root just because their new target is root-writable only.
    target="$wrapper"; mode=self
    if [[ -n "$(owner_user)" ]]; then
      if can_drop_privileges; then mode=owner; else mode=refuse; fi
    fi
  else
    mode="$(entry_mode "$entry" "$target")"
  fi
  case "$mode" in
    owner)  [[ "$action" != heal || "$HEAL_EVENT" -ne 1 ]] || action=event
            out="$(drop_to_owner env AGY_HEAL_LOCKED=1 bash "$SELF" --worker "$action" "$entry" 2>&1)"; rc=$? ;;
    refuse) out="[heal] refused: $entry -> $target — only root can write there, but the path is user-controlled"; rc=1 ;;
    *)      out="$(run_worker "$action" "$entry" 2>&1)"; rc=$? ;;
  esac
  if [[ -n "$out" ]]; then
    printf '%s\n' "$out"
    [[ "$action" == restore ]] || printf '%s\n' "$out" >> "$PREFIX_SH/mitm.log" 2>/dev/null || true
  fi
  return "$rc"
}

locked_main() {
  local entry rc=0
  if [[ "$ACTION" == place ]]; then
    run_entry place "$ENTRY"; exit $?
  fi
  if [[ "$ACTION" == restore-one ]]; then
    run_entry restore "$ENTRY"; exit $?
  fi
  [[ -f "$PREFIX_SH/shim.path" ]] || exit 0
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    run_entry "$ACTION" "$entry" || rc=1
  done < "$PREFIX_SH/shim.path"
  [[ "$ACTION" == restore ]] && exit "$rc"
  exit 0   # a timer-driven heal must not "fail" because of a single entry
}

if [[ -z "${AGY_HEAL_LOCKED:-}" ]]; then
  [[ "$ACTION" == heal && ! -f "$PREFIX_SH/shim.path" ]] && exit 0
  AGY_HEAL_LOCKED=1 with_heal_lock bash "$SELF" "$@"; rc=$?
  if [[ $rc -eq 75 ]]; then
    echo "[heal] another heal is running (lock wait expired) — skipped" >> "$PREFIX_SH/mitm.log" 2>/dev/null || true
    [[ "$ACTION" == heal ]] && exit 0
  fi
  exit "$rc"
fi
locked_main
HEALEOF
} > "$PREFIX/heal.sh"
chmod 755 "$PREFIX/heal.sh"

touch "$PREFIX/shim.path"; chmod 644 "$PREFIX/shim.path"
# binary owner: heal (systemd) runs as root, yet it must work with files in the user's
# directory as that user (see the security model above)
if [[ "$OS" == "Linux" ]]; then
  printf '%s\n' "${SUDO_USER:-$(id -un)}" > "$PREFIX/owner"
  chmod 644 "$PREFIX/owner"
fi
# --- finding agy -------------------------------------------------------------
# Under sudo the PATH is replaced by secure_path, which hides what the user actually runs
# (~/.local/bin, /snap/bin, nvm, bun, cargo...). So we look the way the owner's shell does.
OWNER_CMD=()   # command prefix that runs something as the owner (empty: we already are)
OWNER_NAME="$(owner_user)"
if [[ -n "$OWNER_NAME" ]]; then
  if command -v runuser >/dev/null 2>&1; then OWNER_CMD=(runuser -u "$OWNER_NAME" --)
  elif command -v setpriv >/dev/null 2>&1; then OWNER_CMD=(setpriv --reuid="$OWNER_NAME" --regid="$(id -g "$OWNER_NAME")" --init-groups --)
  else err "runuser or setpriv is needed to work with $OWNER_NAME's files (util-linux)"; fi
fi
run_as_owner() { "${OWNER_CMD[@]+"${OWNER_CMD[@]}"}" "$@"; }
OWNER_HOME="$HOME"
[[ -z "$OWNER_NAME" ]] || OWNER_HOME="$(getent passwd "$OWNER_NAME" | cut -d: -f6)"
[[ -n "$OWNER_HOME" ]] || OWNER_HOME="$HOME"

# the owner's PATH as an interactive login shell sees it (rc files may print noise: take a marked line)
OWNER_PATH=""
if [[ -n "$OWNER_NAME" ]]; then
  capture_owner_path "${OWNER_CMD[@]}" env -i HOME="$OWNER_HOME" USER="$OWNER_NAME" TERM=dumb \
    bash -lic 'printf "\n@@AGYPATH@@%s@@\n" "$PATH"'
fi
OWNER_PATH="${OWNER_PATH:+$OWNER_PATH:}$PATH"

# every directory that may hold agy, most likely first: the owner's PATH, then well-known places
agy_search_dirs() {
  local d
  { printf '%s\n' "$OWNER_PATH" | tr ':' '\n'
    for d in "$OWNER_HOME/.local/bin" "$OWNER_HOME/bin" "$OWNER_HOME/.bun/bin" "$OWNER_HOME/.cargo/bin" \
             "$OWNER_HOME/.npm-global/bin" "$OWNER_HOME/.volta/bin" "$OWNER_HOME/.nix-profile/bin" \
             "$OWNER_HOME"/.nvm/versions/node/*/bin /snap/bin /usr/local/bin /usr/bin /opt/homebrew/bin \
             /home/linuxbrew/.linuxbrew/bin; do printf '%s\n' "$d"; done
  } | awk 'NF && !seen[$0]++'
}

# the agy the user would run. Our own wrapper (a shim with no agy.real beside it) is skipped:
# on a re-install it precedes the launcher in PATH and must not be taken for the program itself
find_agy() {
  local d c
  if [[ -n "${AGY_BYPASS_BIN:-}" ]]; then printf '%s\n' "$AGY_BYPASS_BIN"; return; fi
  while IFS= read -r d; do
    c="$d/agy"
    [[ -f "$c" && -x "$c" ]] || continue
    if is_our_shim "$(resolve_link "$c")" && [[ ! -e "$(resolve_link "$c").real" ]]; then continue; fi
    printf '%s\n' "$c"; return
  done < <(agy_search_dirs)
}

# a directory for the wrapper: it must come BEFORE the launcher in the owner's PATH, belong to the
# owner, and not be a system directory. ~/.local/bin is preferred; otherwise it is created
pick_wrapper_path() {   # $1 = launcher entry
  local entry="$1" dir preferred="" first=""
  while IFS= read -r dir; do
    [[ "$dir" == "$(dirname "$entry")" ]] && break          # what follows loses to the launcher
    [[ -d "$dir" ]] && run_as_owner test -w "$dir" || continue
    case "$dir" in "$OWNER_HOME"/*) ;; *) continue ;; esac
    if [[ "$dir" == "$OWNER_HOME/.local/bin" ]]; then preferred="$dir"; break; fi
    [[ -n "$first" ]] || first="$dir"
  done < <(printf '%s\n' "$OWNER_PATH" | tr ':' '\n' | awk 'NF && !seen[$0]++')
  dir="${preferred:-$first}"
  if [[ -z "$dir" ]]; then
    dir="$OWNER_HOME/.local/bin"
    run_as_owner mkdir -p "$dir" || return 1
  fi
  printf '%s/%s\n' "$dir" "$(basename "$entry")"
}

# where the confined application can read the CA: a snap sees only its own ~/snap/<name>/common
# (and non-hidden files in $HOME); anything else reads the prefix directly
wrapper_ca_dir() {   # $1 = launcher entry, $2 = its resolved target
  local link name snap
  case "$2" in
    /usr/lib/snapd/*|/usr/bin/snap|/snap/*|/var/lib/snapd/*)
      link="$(readlink "$1" 2>/dev/null || true)"; name="$(basename "${link:-$1}")"; snap="${name%%.*}"
      if [[ -d "$OWNER_HOME/snap/$snap" ]]; then printf '%s\n' "$OWNER_HOME/snap/$snap/common/agy-region-fixer"; return; fi ;;
  esac
  printf '%s\n' "$CA_DIR"
}

forget_shim_path() {
  local entry="$1" tmp
  tmp="$(mktemp "$PREFIX/shim.path.XXXXXX")" || err "could not update shim.path"
  if awk -v e="$entry" '$0 != e' "$PREFIX/shim.path" > "$tmp" && mv -f "$tmp" "$PREFIX/shim.path"; then
    chmod 644 "$PREFIX/shim.path"
  else rm -f "$tmp"; err "could not update shim.path"; fi
}

# Missing launchers must not leave their wrappers ahead of a replacement CLI in PATH.
# Removal uses the same lock and owner privileges as heal, including for a vanished Nix profile.
prune_missing_wrappers() {
  local entry wrapper ca_dir tmp
  [[ -f "$WRAPPERS_FILE" ]] || return 0
  while IFS=$'\t' read -r entry wrapper ca_dir; do
    [[ -n "$entry" && ! -e "$entry" ]] || continue
    "$PREFIX/heal.sh" --restore-entry "$entry" || err "could not remove the stale wrapper for $entry"
    forget_shim_path "$entry"
    tmp="$(mktemp "$WRAPPERS_FILE.XXXXXX")" || err "could not update wrappers.path"
    if awk -F'\t' -v e="$entry" '$1 != e' "$WRAPPERS_FILE" > "$tmp" && mv -f "$tmp" "$WRAPPERS_FILE"; then
      chmod 644 "$WRAPPERS_FILE"
    else rm -f "$tmp"; err "could not update wrappers.path"; fi
  done < "$WRAPPERS_FILE"
}

register_wrapper() {   # $1 entry, $2 wrapper, $3 CA dir; one owner per entry and wrapper
  local old_entry old_wrapper old_ca
  case "$1$2$3" in *$'\t'* | *$'\n'*) err "tabs and newlines in agy paths are not supported" ;; esac
  if [[ -f "$WRAPPERS_FILE" ]]; then
    while IFS=$'\t' read -r old_entry old_wrapper old_ca; do
      [[ "$old_entry" == "$1" || "$old_wrapper" == "$2" ]] || continue
      "$PREFIX/heal.sh" --restore-entry "$old_entry" || err "could not replace the wrapper for $old_entry"
      [[ "$old_entry" == "$1" ]] || forget_shim_path "$old_entry"
    done < "$WRAPPERS_FILE"
  fi
  { awk -F'\t' -v e="$1" -v w="$2" '$1 != e && $2 != w' "$PREFIX/wrappers.path" 2>/dev/null || true
    printf '%s\t%s\t%s\n' "$1" "$2" "$3"; } > "$PREFIX/wrappers.path.tmp"
  mv -f "$PREFIX/wrappers.path.tmp" "$PREFIX/wrappers.path"; chmod 644 "$PREFIX/wrappers.path"
}

prune_missing_wrappers
AGY_BIN="$(find_agy || true)"
WRAPPER_NEEDS_PATH=0; SMOKE_BIN="${AGY_BIN:-}"
if [[ -n "$AGY_BIN" ]]; then
  # shim.path holds the path under which agy is visible in PATH (may be a symlink):
  # heal resolves it on every run, so switching the link to a new
  # version (brew/npm) does not go unnoticed
  RESOLVED="$(resolve_link "$AGY_BIN")"
  if is_launcher "$RESOLVED"; then
    # snap/nix: the launcher cannot be replaced — a wrapper earlier in the user's PATH does the job
    WRAP_PATH="$(pick_wrapper_path "$AGY_BIN")" || err "could not prepare a directory for the wrapper"
    # pick_wrapper_path runs in a subshell: decide PATH precedence here, in the installer.
    WRAPPER_DIR="$(dirname "$WRAP_PATH")"
    WRAPPER_NEEDS_PATH=1
    while IFS= read -r SEARCH_DIR; do
      if [[ "$SEARCH_DIR" == "$WRAPPER_DIR" ]]; then WRAPPER_NEEDS_PATH=0; break; fi
      [[ "$SEARCH_DIR" != "$(dirname "$AGY_BIN")" ]] || break
    done < <(printf '%s\n' "$OWNER_PATH" | tr ':' '\n')
    register_wrapper "$AGY_BIN" "$WRAP_PATH" "$(wrapper_ca_dir "$AGY_BIN" "$RESOLVED")"
    say "agy is a launcher ($AGY_BIN -> $RESOLVED): not touching it, installing a wrapper $WRAP_PATH"
    SMOKE_BIN="$WRAP_PATH"
  else
    [[ "$RESOLVED" == "$AGY_BIN" ]] || say "agy is a symlink ($AGY_BIN -> $RESOLVED): placing the shim next to the real binary"
  fi
  grep -qxF "$AGY_BIN" "$PREFIX/shim.path" 2>/dev/null || printf '%s\n' "$AGY_BIN" >> "$PREFIX/shim.path"
  "$PREFIX/heal.sh" --place "$AGY_BIN" || err "failed to install the shim for $AGY_BIN (details above and in $PREFIX/mitm.log)"
  if [[ "$WRAPPER_NEEDS_PATH" -eq 1 ]]; then
    say "⚠️  $(dirname "$WRAP_PATH") is not in your PATH ahead of $(dirname "$AGY_BIN"): add this to your shell profile"
    say "    export PATH=\"$(dirname "$WRAP_PATH"):\$PATH\""
  fi
else
  say "agy not found in PATH — not installing the shim. Install Antigravity CLI and rerun the installer."
fi

# ---------------------------------------------------------------------------
say "5/6 Shim self-healing after CLI updates (events + every 5 minutes)"
"$PREFIX/heal.sh"   # propagate the selected port to every registered owned shim
# what the path units/WatchPaths should watch: the path from shim.path and its resolved target (no duplicates)
watch_targets() {
  local p r w
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    r="$(resolve_link "$p")"
    if is_launcher "$r"; then
      # the launcher is never modified: what can disappear or be overwritten is our wrapper
      w="$(wrapper_field "$p" 2)"; [[ -z "$w" ]] || printf '%s\n' "$w" "$(dirname "$w")"
      continue
    fi
    printf '%s\n' "$p" "$(dirname "$p")"
    [[ "$r" == "$p" ]] || printf '%s\n' "$r" "$(dirname "$r")"
  done < "$PREFIX/shim.path" | awk '!seen[$0]++'
}

if [[ "$OS" == "Linux" ]]; then
  ln -sf "$PREFIX/heal.sh" /usr/local/bin/agy-bypass-heal
  cat > /etc/systemd/system/agy-region-fixer-heal.service <<UNIT2
[Unit]
Description=Restore agy region-fixer shim after CLI updates
# no start rate limit: with the default (5 starts in 10 s) a burst of writes to agy
# fails the service with start-limit-hit, and the path unit fails with it until reboot.
# Heal is an idempotent oneshot without Restart= and writes nothing once the shim is
# in place, so it cannot loop on its own triggers
StartLimitIntervalSec=0

[Service]
Type=oneshot
ExecStart="$PREFIX/heal.sh"
UNIT2
  cat > /etc/systemd/system/agy-region-fixer-heal-event.service <<UNITEVENT
[Unit]
Description=Restore agy region-fixer shim after a filesystem event
StartLimitIntervalSec=0

[Service]
Type=oneshot
ExecStart="$PREFIX/heal.sh" --event
UNITEVENT
  cat > /etc/systemd/system/agy-region-fixer-heal.timer <<UNIT3
[Unit]
Description=Heal agy shim every 5 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
UNIT3
  # PathChanged coalesces writer-close events; direct parents catch rename/link
  # switches without recursive watches. The independent timer stays
  # as a safety net. % is special in unit values — escape it
  PATH_LINES=""
  while IFS= read -r p; do
    p="${p//\%/%%}"
    PATH_LINES="${PATH_LINES}PathChanged=$p
"
  done < <(watch_targets)
  PATH_UNIT=/etc/systemd/system/agy-region-fixer-heal.path
  if [[ -n "$PATH_LINES" ]]; then
    cat > "$PATH_UNIT" <<UNIT4
[Unit]
Description=Heal agy shim when the CLI binary changes

[Path]
${PATH_LINES}Unit=agy-region-fixer-heal-event.service

[Install]
WantedBy=multi-user.target
UNIT4
  else
    # CLI not found — nothing to watch; remove the stale path unit from a previous install
    systemctl disable --now agy-region-fixer-heal.path >/dev/null 2>&1 || true
    rm -f "$PATH_UNIT"
  fi
  systemctl daemon-reload
  # a re-install revives units an earlier version left in the failed state
  systemctl reset-failed agy-region-fixer-heal.service agy-region-fixer-heal-event.service agy-region-fixer-heal.path >/dev/null 2>&1 || true
  systemctl enable --now agy-region-fixer-heal.timer >/dev/null 2>&1 \
    || say "⚠️  failed to enable the heal timer — restore the shim manually after a CLI update: sudo agy-bypass-heal"
  # enable the path unit only if it exists: it is not created when no CLI was found
  if [[ -f "$PATH_UNIT" ]]; then
    systemctl enable --now agy-region-fixer-heal.path >/dev/null 2>&1 \
      || say "⚠️  failed to enable the heal path unit — only the every-5-minutes timer works"
  fi
else
  # WatchPaths observes direct paths/parents; the separate timer can recover a
  # persistently missing target. Throttling still limits launchd wake-up latency.
  WATCH_LINES=""
  while IFS= read -r p; do
    WATCH_LINES="${WATCH_LINES}    <string>$(xml_esc "$p")</string>
"
  done < <(watch_targets)
  X_PREFIX="$(xml_esc "$PREFIX")"
  HEAL_PLIST="$HOME/Library/LaunchAgents/com.agy.region-fixer-heal.plist"
  cat > "$HEAL_PLIST" <<PLISTEOF2
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.agy.region-fixer-heal</string>
  <key>ProgramArguments</key><array>
    <string>/bin/bash</string><string>$X_PREFIX/heal.sh</string><string>--event</string>
  </array>
  <key>ThrottleInterval</key><integer>1</integer>
  <key>WatchPaths</key><array>
${WATCH_LINES}</array>
  <key>RunAtLoad</key><true/>
</dict></plist>
PLISTEOF2
  launchctl bootout "gui/$(id -u)" "$HEAL_PLIST" >/dev/null 2>&1 || true
  launchctl bootstrap "gui/$(id -u)" "$HEAL_PLIST" || launchctl load -w "$HEAL_PLIST"
  TIMER_PLIST="$HOME/Library/LaunchAgents/com.agy.region-fixer-heal-timer.plist"
  cat > "$TIMER_PLIST" <<PLISTTIMER
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.agy.region-fixer-heal-timer</string>
  <key>ProgramArguments</key><array>
    <string>/bin/bash</string><string>$X_PREFIX/heal.sh</string>
  </array>
  <key>StartInterval</key><integer>300</integer>
</dict></plist>
PLISTTIMER
  launchctl bootout "gui/$(id -u)" "$TIMER_PLIST" >/dev/null 2>&1 || true
  launchctl bootstrap "gui/$(id -u)" "$TIMER_PLIST" || launchctl load -w "$TIMER_PLIST"
fi

# ---------------------------------------------------------------------------
say "6/6 Uninstall script"
{
  printf '#!/bin/bash\nset -euo pipefail\nPREFIX_SH=%q\n' "$PREFIX"
  cat <<'UNISTEOF'
OS="$(uname -s)"
if [[ "$OS" == "Linux" ]]; then
  [[ $EUID -eq 0 ]] || { echo "sudo required"; exit 1; }
  systemctl disable --now agy-region-fixer.service agy-region-fixer-heal.timer agy-region-fixer-heal.path agy-region-fixer-heal-event.service 2>/dev/null || true
  rm -f /etc/systemd/system/agy-region-fixer.service
  rm -f /etc/systemd/system/agy-region-fixer-heal.service /etc/systemd/system/agy-region-fixer-heal-event.service /etc/systemd/system/agy-region-fixer-heal.timer /etc/systemd/system/agy-region-fixer-heal.path
  rm -f /usr/local/bin/agy-bypass-heal
  systemctl daemon-reload
else
  UID_=$(id -u)
  launchctl bootout "gui/$UID_" "$HOME/Library/LaunchAgents/com.agy.region-fixer.plist" 2>/dev/null || true
  launchctl bootout "gui/$UID_" "$HOME/Library/LaunchAgents/com.agy.region-fixer-heal.plist" 2>/dev/null || true
  launchctl bootout "gui/$UID_" "$HOME/Library/LaunchAgents/com.agy.region-fixer-heal-timer.plist" 2>/dev/null || true
  rm -f "$HOME/Library/LaunchAgents/com.agy.region-fixer.plist" "$HOME/Library/LaunchAgents/com.agy.region-fixer-heal.plist" "$HOME/Library/LaunchAgents/com.agy.region-fixer-heal-timer.plist"
fi
# put the binaries back — under the same lock and the same privilege rules as heal
# (waits for a heal already in progress: otherwise it would put the shim back over the restored binary)
if [[ -f "$PREFIX_SH/shim.path" ]]; then
  "$PREFIX_SH/heal.sh" --restore || echo "warning: some binaries were not restored (see above) — the prefix is removed anyway; agy.real sits next to agy"
fi
rm -rf "$PREFIX_SH"
echo "Fully removed."
UNISTEOF
} > "$PREFIX/uninstall.sh"
chmod 755 "$PREFIX/uninstall.sh"

# --- smoke test through agy, if it exists and is logged in ---
smoke_succeeded() {
  [[ "$1" -eq 0 ]] || return 1
  # Ignore terminal colours, but never accept an echoed prompt containing the token.
  "$PYBIN" -I -c '
import re, sys
with open(sys.argv[1], encoding="utf-8", errors="replace") as output:
    matched = any(re.sub(r"\x1b\[[0-?]*[ -/]*[@-~]", "", line).strip() == "BYPASS_OK" for line in output)
sys.exit(0 if matched else 1)
' "$2"
}
if [[ -n "${AGY_BIN:-}" ]] && { [[ -f "$(resolve_link "$AGY_BIN")" ]] || is_launcher "$(resolve_link "$AGY_BIN")"; }; then
  say "Smoke test: agy -p (up to 120 s)"
  # output goes to a file, not a pipe: agy child processes holding a pipe will not extend the wait.
  # It runs as the owner: that is who is logged in to agy (root has no credentials of its own)
  SMOKE_OUT="$(mktemp)"
  SMOKE_STATUS=0
  if [[ -n "$OWNER_NAME" ]]; then
    run_with_timeout 120 "${OWNER_CMD[@]}" env "PATH=$(dirname "$SMOKE_BIN"):$OWNER_PATH" "$SMOKE_BIN" -p 'Reply exactly: BYPASS_OK' </dev/null >"$SMOKE_OUT" 2>&1 || SMOKE_STATUS=$?
  else
    run_with_timeout 120 "$SMOKE_BIN" -p 'Reply exactly: BYPASS_OK' </dev/null >"$SMOKE_OUT" 2>&1 || SMOKE_STATUS=$?
  fi
  OUT="$(tail -n 1 "$SMOKE_OUT" 2>/dev/null || true)"
  if smoke_succeeded "$SMOKE_STATUS" "$SMOKE_OUT"; then
    say "✅ Model reply: BYPASS_OK — the bypass works"
  else
    say "⚠️  agy did not reply BYPASS_OK: $OUT"
    say "    if 'not logged in' — run agy login and just use it;"
    say "    if eligibility — enable the diagnostic: touch $PREFIX/verbose.flag, run agy once, read $PREFIX/mitm.log"
  fi
  rm -f "$SMOKE_OUT"
fi

say "Ready. Proxy: 127.0.0.1:$PORT | log: $PREFIX/mitm.log | uninstall: bash $PREFIX/uninstall.sh"
