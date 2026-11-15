<div align="center">

<img src="assets/hero.svg" width="800" alt="Installer runs six steps, then agy replies BYPASS_OK"><br><br>

<img src="assets/linux.svg" height="28" alt="Linux"> <img src="assets/macos.svg" height="28" alt="macOS"> <img src="assets/windows.svg" height="28" alt="Windows"><br>
<img src="assets/bash.svg" height="28" alt="Bash"> <img src="assets/powershell.svg" height="28" alt="PowerShell"> <img src="assets/python.svg" height="28" alt="Python"><br>
<img src="assets/mitmproxy.svg" height="28" alt="mitmproxy"> <img src="assets/selfheal.svg" height="28" alt="self-healing"> <img src="assets/noroot.svg" height="28" alt="heal runs as file owner"> <img src="assets/license.svg" height="28" alt="MIT"><br><br>

<a href="README.md">🇬🇧 English</a> · <a href="README.ru.md">🇷🇺 Русский</a> · <a href="README.zh.md">🇨🇳 中文</a>

<br><br>
<a href="https://github.com/nazavod777/agy-region-fixer/actions/workflows/cross-platform-test.yml"><img src="https://github.com/nazavod777/agy-region-fixer/actions/workflows/cross-platform-test.yml/badge.svg" alt="CI"></a>

</div>

# 🌍 agy-region-fixer

> **Antigravity CLI region-block bypass** — one installer for 🐧 Linux, 🍎 macOS and 🪟 Windows that survives CLI updates.

Google restricts access by the account's country. A local MITM proxy strips `ineligibleTiers` from the `loadCodeAssist` response — the CLI sees only `allowedTiers` and lets you in. Requests to Google are **not modified**, the `agy` binary is **not patched**.

> [!WARNING]
> Bypassing a regional restriction violates Google's ToS. Use at your own risk, only with your own account and subscription.

## ✨ Features

| Feature | What it means |
|---|---|
| 🧩 **No patching** | `agy` stays untouched and sits next to the shim as `agy.real` |
| ⚡ **Event-triggered self-healing** | file-system events trigger repair; a five-minute fallback remains enabled |
| 🛡️ **Guarded repair** | on Linux it drops privileges for user-writable targets; readiness checks and a lock reduce update races |
| 🔒 **Localhost only** | the proxy listens on `127.0.0.1`; only `*.googleapis.com` responses are cleaned |
| 🧪 **Cross-platform CI** | lifecycle workflow for Linux / macOS / Windows: install → update → heal → uninstall |
| 🧹 **Clean uninstall** | `uninstall` puts the binary back and removes everything else |

## 🎯 What it fixes

Exactly **one** thing — the region warning that Antigravity CLI shows right after start:

<div align="center">
<img src="assets/before-after.svg" width="720" alt="Before: Eligibility check failed because the account is not available in your location. After: agy answers normally.">
<br><sub>Illustration of the message and of the result, not a literal screenshot.</sub>
</div>

> `Eligibility check failed: Your current account is not eligible for Antigravity, because it is not currently available in your location.`

| ✅ Fixes | ❌ Does not fix |
|---|---|
| The region **Eligibility Check** error above | Login — you still need a working `agy login` |
| | Subscription, quota or rate limits |
| | Model availability or any server-side restriction on the account |
| | Any other error — if the message differs, this tool will not help |

## 🚀 Installation

Install and log in to Antigravity CLI first (`agy login`), then:

<table>
<tr><td>🐧 <b>Linux</b><br><sub>systemd: Ubuntu, Debian, Kali, Fedora, Arch, openSUSE</sub></td><td>

```bash
curl -fsSL https://raw.githubusercontent.com/nazavod777/agy-region-fixer/master/install.sh | sudo bash
```

</td></tr>
<tr><td>🍎 <b>macOS</b><br><sub>12+, Xcode Command Line Tools</sub></td><td>

```bash
curl -fsSL https://raw.githubusercontent.com/nazavod777/agy-region-fixer/master/install.sh | bash
```

</td></tr>
<tr><td>🪟 <b>Windows 10/11</b><br><sub>Python 3.12/3.13 from python.org, no admin rights needed</sub></td><td>

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "iex (irm https://raw.githubusercontent.com/nazavod777/agy-region-fixer/master/install.ps1)"
```

</td></tr>
</table>

> [!NOTE]
> The `curl | bash` and `iex (irm …)` one-liners fetch `addon.py` from raw.githubusercontent.com. Prefer to review first? Clone the repo and run `bash install.sh` / `install.ps1` from its directory — `addon.py` is picked up next to it. To use your own copy, set `AGY_ADDON_URL=...`.

**What the installer does:** installs mitmproxy into an isolated venv (system Python untouched) → sets up proxy autostart (systemd / launchd / HKCU Run) → moves the real binary to `agy.real` and installs a shim → enables self-healing → runs an `agy -p` smoke test.

### 📋 Requirements

- 🐍 Python **3.12 or 3.13** (required by mitmproxy 12.x), a complete build with `ctypes`, `ssl` and `zlib`. The installer checks every `python3.13`/`python3.12`/`python3` on `PATH` and skips incomplete ones — e.g. a self-built Python without `libffi-dev`
- 🌐 `curl`, and an installed, logged-in Antigravity CLI
- 📦 **Any way of installing `agy`** — the installer finds it the way your own shell does (`sudo` hides `~/.local/bin`, `/snap/bin`, nvm, bun, cargo…):
  - a plain binary, an npm/brew/cargo link, a root-owned `/usr/local/bin/agy` → the binary is moved to `agy.real` and replaced by the shim;
  - **snap, Nix** (a launcher that must not be touched) → the launcher stays as is, and a wrapper is placed earlier in your `PATH` (`~/.local/bin`). For a snap the CA certificate is copied into `~/snap/<name>/common/agy-region-fixer`, where the confined app can read it.
- 🪟 **One Windows installer for all supported formats:** `install.ps1` detects a plain EXE, npm `.cmd`/`.ps1`, a WindowsApps alias or a Scoop shim. It builds a real `agy.exe` wrapper using the .NET Framework compiler included with Windows. Plain binaries are saved as `agy.real.exe`; managed launchers keep their names and files, with the wrapper in `%USERPROFILE%\.agy-region-fixer\bin`. Old `agy.cmd` installations are migrated automatically.
- 🐧 Linux: systemd plus `runuser` or `setpriv` (both ship in `util-linux`)

## ⚙️ How it works

```mermaid
flowchart LR
    U([👤 agy]) --> S{{"🪄 shim"}}
    S -- "proxy alive" --> E["🔐 SSL_CERT_FILE + HTTPS_PROXY"]
    S -- "proxy not answering" --> R
    E --> R["📦 agy.real"]
    R --> P["🛰️ mitmproxy 127.0.0.1:PORT<br/>+ addon.py"]
    P -- "ineligibleTiers → []" --> G[("☁️ *.googleapis.com")]
```

- `agy` → shim → if the proxy is alive, sets `SSL_CERT_FILE` (local CA) and `HTTPS_PROXY=127.0.0.1:PORT` → the real binary `agy.real`
- if the proxy is down the shim just calls `agy` without it: you get the old eligibility error, but nothing breaks
- by default the log holds only cleaning facts (`CLEANED …`)

## 🩹 Self-healing after CLI updates

File-system events trigger shim repair after a CLI update. A five-minute fallback remains enabled on every platform; no permanent loop polls the CLI file every second.

| OS | Event trigger | Fallback |
|---|---|---|
| 🐧 Linux | systemd path unit with `PathChanged` | systemd timer |
| 🍎 macOS | launchd `WatchPaths` | separate `StartInterval` job |
| 🪟 Windows | .NET `FileSystemWatcher`, started at installation and user logon | scheduled task `agy-region-fixer-heal` |

Events are coalesced before repair. The healer waits for a quiet candidate and checks its size (≥ 10 MB; on Windows also the `MZ` signature). It uses a lock, a staged copy and rollback checks to reduce races and preserve the previous working copy. These checks are a readiness heuristic: a quiet file does not prove that an arbitrary updater has finished.

If an updater deletes an in-place target before creating its replacement, event-triggered repair leaves it `Pending` rather than restoring the shim into that gap. If the target stays missing, a manual run or the five-minute fallback repairs it from the saved binary. Managed launchers remain untouched; only this tool's wrapper is repaired.

On Windows, moving or renaming higher-level directories, such as the user profile, may require stopping the watcher first. The five-minute fallback does not release directory handles or unblock such a move.

Run repair manually:

- 🐧 `sudo agy-bypass-heal`
- 🍎 `bash ~/.agy-region-fixer/heal.sh`
- 🪟 `powershell %USERPROFILE%\.agy-region-fixer\heal.ps1`

## 🔐 Security model

On Linux heal is started by root (systemd) while the directory holding `agy` usually belongs to the user. So that the user cannot turn this into a root-level write (a planted symlink, a race on a temp file):

- 👤 when the recorded installation owner can write to the target directory, heal runs as that user (`runuser`/`setpriv`); root may handle paths whose entry and target directories are both outside that user’s write access
- 🚫 if only root can write to the target directory while the `agy` path sits in a user-controlled one (e.g. a link to a system file), heal **refuses** instead of acting as root
- 🔑 staged binary copies preserve the original owner, group and ordinary permission bits; a root worker applies `fchown` before restoring the mode, and candidates with `setuid`/`setgid` bits are rejected before copying
- 🧱 `AGY_BYPASS_PREFIX` is validated: absolute path, not `/` or `$HOME`, no `\ " ' % $` characters
- 🌐 the proxy listens on `127.0.0.1` only; keys and tokens never leave the machine

## 🔧 Configuration

| Variable | Default | Purpose | OS |
|---|---|---|---|
| `AGY_BYPASS_PORT` | automatic | proxy port | 🐧 🍎 🪟 |
| `AGY_BYPASS_PREFIX` | `/opt/agy-region-fixer` · `~/.agy-region-fixer` | install directory | 🐧 🍎 |
| `AGY_BYPASS_BIN` | `agy` found in `PATH` | path to the CLI binary | 🐧 🍎 |
| `AGY_ADDON_URL` | raw.githubusercontent.com | where to fetch `addon.py` for a piped install | 🐧 🍎 🪟 |

The default is a randomly selected free localhost port in `49152–65535`, saved in `<install directory>/port`. A reinstall reuses that high port when available; otherwise it selects another. `AGY_BYPASS_PORT` explicitly fixes the port and fails if it is occupied. The installer prints the actual address and updates the proxy and all wrappers together. Ctrl+C stops the installer and its temporary commands; an already started background proxy remains until you run uninstall.

```bash
AGY_BYPASS_PORT=8081 bash install.sh          # Linux: with sudo
```
```powershell
$env:AGY_BYPASS_PORT="8081"; powershell -ExecutionPolicy Bypass -File install.ps1
```

## 🧹 Uninstall

- 🐧 `sudo /opt/agy-region-fixer/uninstall.sh`
- 🍎 `bash ~/.agy-region-fixer/uninstall.sh`
- 🪟 `powershell -ExecutionPolicy Bypass -File %USERPROFILE%\.agy-region-fixer\uninstall.ps1`

Removes the proxy, tasks and shim; the `agy` binary goes back in place — even if an interrupted update left it only as `agy.real`.

## 🩺 Diagnostics

| OS | Proxy log | Service log |
|---|---|---|
| 🐧 Linux | `/opt/agy-region-fixer/mitm.log` | `journalctl -u agy-region-fixer -e` |
| 🍎 macOS | `~/.agy-region-fixer/mitm.log` | `~/.agy-region-fixer/launchd.err` |
| 🪟 Windows | `%USERPROFILE%\.agy-region-fixer\mitm.log` | `…\mitm-stdout.log` |

🔎 **Verbose mode:** logging every URL is switched on with a `verbose.flag` file in the install directory (`touch /opt/agy-region-fixer/verbose.flag`; on Windows create the file in `%USERPROFILE%\.agy-region-fixer`). No proxy restart needed — the flag is checked on every request; delete the file to turn it off.

🔬 In verbose mode the addon also logs the **shape** of every JSON answer from Google (`SHAPE <method> <url> <status> -> {field: type}`): field names and types only, never values (except enumerations such as `reasonCode` and `tierId`). If the warning stays after installing, this is what shows whether the API changed — attach the `SHAPE` lines to an issue.

The proxy runs `addon.py` directly with the venv's Python (`python -I addon.py --port PORT --confdir CA_DIR`), registering the filtering hooks once. It does not use mitmdump's script autoreloader or poll the addon file every second. Changes to `addon.py` take effect after a proxy restart; rerunning the installer restores the files and restarts it. A custom `AGY_ADDON_URL` can still provide a hook-only mitmproxy addon: it is saved as `custom-addon.py` and loaded once by the standard bootstrap through `--addon`. Changes to that file also require a proxy restart. Use the uninstall script to remove the installation.

## ⚠️ Limitations

- 🪟 For launcher-based Windows installations, open a new terminal after installation to pick up the updated user `PATH`. Programs must resolve the installed `agy.exe` wrapper or launch its full path; an absolute call to the original managed launcher bypasses it. A system `PATH` entry can take precedence over the user `PATH`; check which `agy` your application resolves.
- 🧬 If Google changes the response format (renames the field or moves to binary proto) the addon stops cleaning; fixed with a one-line change in `addon.py`.
- 📌 If `agy` starts certificate pinning (Go clients almost never do) this approach would need rework.

## ✅ Test status

The native GitHub Actions jobs linked below passed. Linux and macOS were tested at `bc1495b`; Windows passed at `2cda8ef`, after changes limited to the Windows installer, watcher tests and Windows CI step.

| 🐧 ubuntu-latest | 🍎 macos-latest | 🪟 windows-latest |
|:---:|:---:|:---:|
| [✅ systemd](https://github.com/nazavod777/agy-region-fixer/actions/runs/43772344364/job/132990856460) | [✅ launchd](https://github.com/nazavod777/agy-region-fixer/actions/runs/43772344364/job/132990856534) | [✅ HKCU Run + schtasks](https://github.com/nazavod777/agy-region-fixer/actions/runs/43773308497/job/132993835041) |

The checks use a synthetic CLI and cover the proxy and CA, event-triggered automatic repair, watcher scenarios and uninstall. The Windows job also verified HTTPS through the proxy and rejection of an incorrect CA. CI does not test real `agy login` or real CLI requests to Google's API. Windows runs with administrator privileges and UAC disabled, so Task Scheduler under a standard user account and a real AppExecAlias remain unverified.

The earlier live Linux check with the real CLI and model returned `BYPASS_OK`; it is a historical result, not a new check of this revision.

## 🗂️ Layout

```
agy-region-fixer/
├── install.sh      # 🐧🍎 Linux / macOS installer (generates heal.sh, uninstall.sh)
├── install.ps1     # 🪟 Windows installer
├── addon.py        # 🧩 mitmproxy addon — the single source of the cleaning logic
├── assets/         # 🎨 README SVGs
└── .github/workflows/cross-platform-test.yml
```

## 🤝 Credits

| Role | Who |
|---|---|
| 👤 **Author & maintainer** | [**nazavod777**](https://github.com/nazavod777) |
| 🤖 **Built with AI tools** | **Claude** & **Claude Code** (Anthropic) · **Hermes** (agent harness) · **GLM** models (Z.ai) · **T3 Code** (terminal) |

The AI tools above were used as development assistants — thanks to their teams. Design decisions, review and responsibility for the code stay with the author.

## 📄 License

[MIT](LICENSE)

---

<div align="center"><sub>Like the project? Support the author ☕</sub></div>

<div align="center">

<a href="https://nazavod.dev"><img src="assets/site.svg" height="28" alt="nazavod.dev"></a> <a href="https://t.me/bio_nazavod"><img src="assets/telegram.svg" height="28" alt="Telegram"></a> <a href="https://github.com/nazavod777"><img src="assets/github.svg" height="28" alt="GitHub"></a> <a href="https://x.com/nazavod777"><img src="assets/x.svg" height="28" alt="X"></a> <a href="https://antidrain.me"><img src="assets/antidrain.svg" height="28" alt="AntiDrain"></a>

<br><br>
<a href="https://nazavod.dev/coffee/"><img src="assets/coffee.svg" width="300" height="54" alt="Buy me a coffee"></a>

</div>
