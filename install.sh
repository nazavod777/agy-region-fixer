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
# (instantly via a path unit/WatchPaths, plus a timer every 5 minutes)
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
PORT="${AGY_BYPASS_PORT:-8080}"
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

# honest TCP probe: ANY listening port counts as busy (curl got confused by non-HTTP)
port_busy() { (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null; }

# escape a string for XML (plist): & < > in paths must not break the file
xml_esc() { sed 's|&|\&amp;|g; s|<|\&lt;|g; s|>|\&gt;|g' <<<"$1"; }

# run a command with a time limit: timeout/gtimeout, and without them (macOS) a watchdog
# process; the watchdog's stdout/stderr are closed, otherwise a pipe into `| tail` would wait for its sleep
run_with_timeout() {
  local secs="$1"; shift
  if command -v timeout  >/dev/null 2>&1; then timeout  "$secs" "$@"; return; fi
  if command -v gtimeout >/dev/null 2>&1; then gtimeout "$secs" "$@"; return; fi
  "$@" & local pid=$!
  ( sleep "$secs"; pkill -P "$pid" 2>/dev/null; kill "$pid" 2>/dev/null ) >/dev/null 2>&1 </dev/null &
  local watchdog=$! rc=0
  disown "$watchdog" 2>/dev/null || true   # no "Terminated" message from job control
  wait "$pid" || rc=$?
  kill "$watchdog" 2>/dev/null || true
  return "$rc"
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
  curl -fsSL "${AGY_ADDON_URL:-$RAW_BASE/addon.py}" -o "$ADDON_SRC" \
    || err "failed to download addon.py (${AGY_ADDON_URL:-$RAW_BASE/addon.py})"
fi
# placeholders are substituted by python as string literals (json.dumps): paths with
# quotes, backslashes and sed metacharacters do not break the addon
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
' "$ADDON_SRC" "$PREFIX/addon.py" "$PREFIX/mitm.log" "$PREFIX/verbose.flag"
[[ "$ADDON_SRC" == "$PREFIX/addon.py.tmpl" ]] && rm -f "$ADDON_SRC"
if grep -q '@@LOG@@\|@@VERBOSE_FLAG@@' "$PREFIX/addon.py"; then
  err "unsubstituted placeholders left in addon.py"
fi
"${CLEAN_ENV[@]}" "$PYBIN" -I -c 'import sys; compile(open(sys.argv[1], encoding="utf-8").read(), sys.argv[1], "exec")' "$PREFIX/addon.py" \
  || err "the generated addon.py does not compile"

# ---------------------------------------------------------------------------
say "3/6 Proxy autostart (port 127.0.0.1:$PORT)"
# a port counts as "ours" only if our service is active AND already sits on this same port;
# otherwise, when reinstalling onto a different port, a foreign listener on the new port would slip
# past the check because the old service is active (old installs have no port file —
# for them the previous logic applies: "service active = ours")
OLD_PORT="$(cat "$PREFIX/port" 2>/dev/null || true)"
port_is_ours() {  # $1 — is our service running right now? (0/1)
  [[ "$1" -eq 0 ]] && [[ -z "$OLD_PORT" || "$OLD_PORT" == "$PORT" ]]
}
if [[ "$OS" == "Linux" ]]; then
  SERVICE_ACTIVE=1; systemctl is-active --quiet agy-region-fixer.service && SERVICE_ACTIVE=0
  if port_busy && ! port_is_ours "$SERVICE_ACTIVE"; then
    err "port $PORT is busy with a service that is not ours; pick another: AGY_BYPASS_PORT=8081 sudo bash $0"
  fi
  cat > /etc/systemd/system/agy-region-fixer.service <<UNIT
[Unit]
Description=Antigravity region fixer (MITM, cleans ineligibleTiers)
After=network-online.target

[Service]
ExecStart="$VENV/bin/mitmdump" -s "$PREFIX/addon.py" -p $PORT --set listen_host=127.0.0.1 --set "confdir=$CA_DIR"
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
  if port_busy && ! port_is_ours "$SERVICE_ACTIVE"; then
    err "port $PORT is busy with a service that is not ours; pick another: AGY_BYPASS_PORT=8081 bash $0"
  fi
  PLIST="$HOME/Library/LaunchAgents/com.agy.region-fixer.plist"
  mkdir -p "$HOME/Library/LaunchAgents"
  X_VENV="$(xml_esc "$VENV")"; X_PREFIX="$(xml_esc "$PREFIX")"; X_CA_DIR="$(xml_esc "$CA_DIR")"
  cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.agy.region-fixer</string>
  <key>ProgramArguments</key><array>
    <string>$X_VENV/bin/mitmdump</string>
    <string>-s</string><string>$X_PREFIX/addon.py</string>
    <string>-p</string><string>$PORT</string>
    <string>--set</string><string>listen_host=127.0.0.1</string>
    <string>--set</string><string>confdir=$X_CA_DIR</string>
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
STABLE_CHECKS=15          # ×2 s = cap on waiting for the size to settle, ~30 s

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
  # normalize ../ (if the file no longer exists — leave as is)
  if [[ -e "$p" ]]; then
    p="$(cd "$(dirname "$p")" && pwd)/$(basename "$p")"
  fi
  printf '%s\n' "$p"
}

# string in single quotes for POSIX sh (locale-independent, unlike printf %q:
# in the C locale it emits $'\320..', which dash does not understand)
sh_quote() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

# shim text for the real binary $1 (absolute path, safe to invoke via a symlink)
render_shim() {
  printf '%s\n' '#!/bin/sh' "# $SHIM_MARKER"
  printf 'PORT=%s\nCA_DIR=%s\nREAL=%s\n' "$(sh_quote "$PORT_SH")" "$(sh_quote "$CA_SH")" "$(sh_quote "$1")"
  cat <<'SHIMBODY'
if curl -s --noproxy '*' -o /dev/null --max-time 2 "http://127.0.0.1:$PORT/"; then
  export SSL_CERT_FILE="$CA_DIR/mitmproxy-ca-cert.pem"
  export HTTPS_PROXY="http://127.0.0.1:$PORT"
fi
exec "$REAL" "$@"
SHIMBODY
}

# atomic write of shim $2 for binary $1: mktemp (O_EXCL, random name) + chmod 755
# before mv — the reader never sees a window of "file exists, x bit missing". Runs with the rights of the
# directory owner (see the security model), so a race on the file name grants no privileges
write_shim() {
  local real="$1" dst="$2" tmp
  tmp="$(mktemp "$dst.XXXXXX")" || return 1
  if render_shim "$real" > "$tmp" && chmod 755 "$tmp" && mv -f "$tmp" "$dst"; then
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

# --- working operations on a single shim.path entry (print log lines) -------
# $1 — shim.path entry, $2 — force: 1 on install (no size check)
shim_entry() {
  local entry="$1" force="$2" target size prev stable i
  target="$(resolve_link "$entry")"
  [[ -e "$target" || -e "$target.real" ]] || return 0
  if is_our_shim "$target"; then
    if [[ "$force" -eq 1 ]]; then
      # reinstall: port/CA may have changed
      write_shim "$target.real" "$target" || { echo "[heal] FAILED to update shim for $target"; return 1; }
      echo "[heal] shim updated: $target"
    fi
    return 0
  fi
  [[ ! -d "$target.real" ]] || { echo "[heal] $target.real is a directory — left as is"; return 1; }
  if [[ -f "$target" ]]; then
    if [[ "$force" -ne 1 ]]; then
      # wait for the size to settle: the updater may still be writing the file. A blind sleep
      # does not help on a slow connection, and an mv mid-write leaves a broken agy.real.
      # Not settled — leave: the next trigger will retry.
      size=0; prev=-1; stable=0
      for i in $(seq 1 "$STABLE_CHECKS"); do
        size=$(wc -c < "$target" 2>/dev/null | tr -d '[:space:]'); size=${size:-0}
        if [[ "$size" = "$prev" ]]; then stable=1; break; fi
        prev="$size"; sleep 2
      done
      if [[ "$stable" -ne 1 ]]; then
        echo "[heal] $target is still being written (size=$size) — left as is"; return 0
      fi
      if [[ "$size" -lt "$MIN_REAL_BYTES" ]]; then
        # not a binary: unfinished update or garbage — do NOT overwrite agy.real
        echo "[heal] suspicious $target (size=$size < $MIN_REAL_BYTES) — left as is"; return 0
      fi
      # the entry may have been switched during the wait (e.g. agy replaced by a symlink):
      # the mv below would then move the new link into agy.real. The change re-triggers heal
      if [[ -L "$target" || "$(resolve_link "$entry")" != "$target" ]]; then
        echo "[heal] $entry changed while waiting — left for the next run"; return 0
      fi
    fi
    mv -f "$target" "$target.real" || { echo "[heal] FAILED to move $target"; return 1; }
  fi
  write_shim "$target.real" "$target" || { echo "[heal] FAILED to write shim for $target"; return 1; }
  if [[ "$force" -eq 1 ]]; then echo "[heal] shim installed: $target (real binary -> $target.real)"
  else echo "[heal] restored $target"; fi
}

# put the real binary back (uninstall). We restore the binary even when agy has vanished
# (interrupted update/heal): otherwise it would stay only under the name agy.real. If
# something foreign sits in agy's place — we leave it alone
restore_entry() {
  local target; target="$(resolve_link "$1")"
  [[ -f "$target.real" ]] || return 0
  if [[ ! -e "$target" ]] || is_our_shim "$target"; then
    mv -f "$target.real" "$target" || { echo "FAILED to restore $target"; return 1; }
    echo "restored: $target"
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
# Heal triggers: systemd path unit (Linux, instant), launchd WatchPaths (macOS),
# a timer every 5 minutes (safety net, all OSes) and a manual run.
{
  printf '#!/bin/bash\nSELF=%q\n. %q\n' "$PREFIX/heal.sh" "$PREFIX/common.sh"
  cat <<'HEALEOF'
ACTION=heal; ENTRY=""
case "${1:-}" in
  --place)   ACTION=place;   ENTRY="${2:?}" ;;
  --restore) ACTION=restore ;;
  --worker)  ACTION="worker:${2:?}"; ENTRY="${3:-}" ;;   # internal: work as the owner
esac

run_worker() {   # $1 = heal|place|restore, $2 = entry
  case "$1" in
    heal)    shim_entry "$2" 0 ;;
    place)   shim_entry "$2" 1 ;;
    restore) restore_entry "$2" ;;
  esac
}

if [[ "$ACTION" == worker:* ]]; then
  run_worker "${ACTION#worker:}" "$ENTRY"; exit $?
fi

# --- layer under the lock ---
run_entry() {   # $1 = heal|place|restore, $2 = entry; prints the log, returns the operation's code
  local action="$1" entry="$2" target mode out rc
  target="$(resolve_link "$entry")"
  mode="$(entry_mode "$entry" "$target")"
  case "$mode" in
    owner)  out="$(drop_to_owner env AGY_HEAL_LOCKED=1 bash "$SELF" --worker "$action" "$entry" 2>&1)"; rc=$? ;;
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
AGY_BIN="${AGY_BYPASS_BIN:-$(command -v agy || true)}"
# under sudo, PATH may not contain the user's ~/.local/bin — look there too
if [[ -z "$AGY_BIN" && -n "${SUDO_USER:-}" ]]; then
  for CAND in "/home/$SUDO_USER/.local/bin/agy" "/home/$SUDO_USER/bin/agy"; do
    [[ -x "$CAND" ]] && AGY_BIN="$CAND" && break
  done
fi
if [[ -n "$AGY_BIN" ]]; then
  # shim.path holds the path under which agy is visible in PATH (may be a symlink):
  # heal resolves it on every run, so switching the link to a new
  # version (brew/npm) does not go unnoticed
  RESOLVED="$(resolve_link "$AGY_BIN")"
  [[ "$RESOLVED" == "$AGY_BIN" ]] || say "agy is a symlink ($AGY_BIN -> $RESOLVED): placing the shim next to the real binary"
  grep -qxF "$AGY_BIN" "$PREFIX/shim.path" 2>/dev/null || printf '%s\n' "$AGY_BIN" >> "$PREFIX/shim.path"
  "$PREFIX/heal.sh" --place "$AGY_BIN" || err "failed to install the shim for $AGY_BIN (details above and in $PREFIX/mitm.log)"
else
  say "agy not found in PATH — not installing the shim. Install Antigravity CLI and rerun the installer."
fi

# ---------------------------------------------------------------------------
say "5/6 Shim self-healing after CLI updates (instant + every 5 minutes)"
# what the path units/WatchPaths should watch: the path from shim.path and its resolved target (no duplicates)
watch_targets() {
  local p r
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    printf '%s\n' "$p"
    r="$(resolve_link "$p")"
    [[ "$r" == "$p" ]] || printf '%s\n' "$r"
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
  cat > /etc/systemd/system/agy-region-fixer-heal.timer <<UNIT3
[Unit]
Description=Heal agy shim every 5 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
UNIT3
  # instant reactor: the path unit watches the binaries from shim.path; the timer stays
  # as a safety net. % is special in unit values — escape it
  PATH_LINES=""
  while IFS= read -r p; do
    p="${p//\%/%%}"
    PATH_LINES="${PATH_LINES}PathModified=$p
PathChanged=$p
"
  done < <(watch_targets)
  PATH_UNIT=/etc/systemd/system/agy-region-fixer-heal.path
  if [[ -n "$PATH_LINES" ]]; then
    cat > "$PATH_UNIT" <<UNIT4
[Unit]
Description=Heal agy shim instantly when the CLI binary changes

[Path]
${PATH_LINES}[Install]
WantedBy=multi-user.target
UNIT4
  else
    # CLI not found — nothing to watch; remove the stale path unit from a previous install
    systemctl disable --now agy-region-fixer-heal.path >/dev/null 2>&1 || true
    rm -f "$PATH_UNIT"
  fi
  systemctl daemon-reload
  # a re-install revives units an earlier version left in the failed state
  systemctl reset-failed agy-region-fixer-heal.service agy-region-fixer-heal.path >/dev/null 2>&1 || true
  systemctl enable --now agy-region-fixer-heal.timer >/dev/null 2>&1 \
    || say "⚠️  failed to enable the heal timer — restore the shim manually after a CLI update: sudo agy-bypass-heal"
  # enable the path unit only if it exists: it is not created when no CLI was found
  if [[ -f "$PATH_UNIT" ]]; then
    systemctl enable --now agy-region-fixer-heal.path >/dev/null 2>&1 \
      || say "⚠️  failed to enable the heal path unit — only the every-5-minutes timer works"
  fi
else
  # instant reactor: WatchPaths watches the binaries from shim.path; StartInterval is the safety net
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
    <string>/bin/bash</string><string>$X_PREFIX/heal.sh</string>
  </array>
  <key>WatchPaths</key><array>
${WATCH_LINES}</array>
  <key>StartInterval</key><integer>300</integer>
  <key>RunAtLoad</key><true/>
</dict></plist>
PLISTEOF2
  launchctl bootout "gui/$(id -u)" "$HEAL_PLIST" >/dev/null 2>&1 || true
  launchctl bootstrap "gui/$(id -u)" "$HEAL_PLIST" || launchctl load -w "$HEAL_PLIST"
fi

# ---------------------------------------------------------------------------
say "6/6 Uninstall script"
{
  printf '#!/bin/bash\nset -euo pipefail\nPREFIX_SH=%q\n' "$PREFIX"
  cat <<'UNISTEOF'
OS="$(uname -s)"
if [[ "$OS" == "Linux" ]]; then
  [[ $EUID -eq 0 ]] || { echo "sudo required"; exit 1; }
  systemctl disable --now agy-region-fixer.service agy-region-fixer-heal.timer agy-region-fixer-heal.path 2>/dev/null || true
  rm -f /etc/systemd/system/agy-region-fixer.service
  rm -f /etc/systemd/system/agy-region-fixer-heal.service /etc/systemd/system/agy-region-fixer-heal.timer /etc/systemd/system/agy-region-fixer-heal.path
  rm -f /usr/local/bin/agy-bypass-heal
  systemctl daemon-reload
else
  UID_=$(id -u)
  launchctl bootout "gui/$UID_" "$HOME/Library/LaunchAgents/com.agy.region-fixer.plist" 2>/dev/null || true
  launchctl bootout "gui/$UID_" "$HOME/Library/LaunchAgents/com.agy.region-fixer-heal.plist" 2>/dev/null || true
  rm -f "$HOME/Library/LaunchAgents/com.agy.region-fixer.plist" "$HOME/Library/LaunchAgents/com.agy.region-fixer-heal.plist"
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
if [[ -n "${AGY_BIN:-}" ]] && [[ -f "$(resolve_link "$AGY_BIN")" ]]; then
  say "Smoke test: agy -p (up to 120 s)"
  # output goes to a file, not a pipe: agy child processes holding a pipe will not extend the wait
  SMOKE_OUT="$(mktemp)"
  run_with_timeout 120 "$AGY_BIN" -p 'Reply exactly: BYPASS_OK' </dev/null >"$SMOKE_OUT" 2>&1 || true
  OUT="$(tail -n 1 "$SMOKE_OUT" 2>/dev/null || true)"
  if grep -q BYPASS_OK "$SMOKE_OUT" 2>/dev/null; then
    say "✅ Model reply: $OUT — the bypass works"
  else
    say "⚠️  agy did not reply BYPASS_OK: $OUT"
    say "    if 'not logged in' — run agy login and just use it;"
    say "    if eligibility — check the log: $PREFIX/mitm.log"
  fi
  rm -f "$SMOKE_OUT"
fi

say "Ready. Proxy: 127.0.0.1:$PORT | log: $PREFIX/mitm.log | uninstall: bash $PREFIX/uninstall.sh"
