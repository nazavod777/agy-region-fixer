# ============================================================================
# agy-region-fixer — Antigravity CLI region bypass, Windows installer
# Requirements: Windows 10/11, Python 3.12 or 3.13 from python.org (tick
#             "Add to PATH"; mitmproxy 12.x does not support 3.14+ or <3.12),
#             an installed and logged-in Antigravity CLI (run agy login beforehand).
# Administrator rights are NOT needed (autostart via HKCU Run).
#
# Install:    powershell -ExecutionPolicy Bypass -File install.ps1
# Custom port: $env:AGY_BYPASS_PORT=8081; powershell ... install.ps1
# Uninstall:  powershell -ExecutionPolicy Bypass -File $HOME\.agy-region-fixer\uninstall.ps1
#
# How it works: a local MITM proxy (mitmproxy) strips ineligibleTiers
# from Google loadCodeAssist responses. The agy.exe binary is NOT modified.
# The shim (agy.cmd + agy.real.exe) is self-healed by a scheduled task
# every 5 minutes after CLI updates.
#
# The proxy addon lives in addon.py next to this script (in the repo); for a
# pipe install (iex (irm ...)) it is downloaded from raw.githubusercontent.com
# (override with $env:AGY_ADDON_URL).
# ============================================================================
$ErrorActionPreference = "Stop"
$PREFIX  = Join-Path $env:USERPROFILE ".agy-region-fixer"
$PORT    = if ($env:AGY_BYPASS_PORT) { $env:AGY_BYPASS_PORT } else { "8080" }
$CA_DIR  = Join-Path $PREFIX "ca"
$PIN     = "mitmproxy==12.3.1"
$RUNKEY  = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
$RAWBASE = "https://raw.githubusercontent.com/nazavod777/agy-region-fixer/master"

function Say($m) { Write-Host "==>" $m -ForegroundColor Green }
function Die($m) { Write-Host "ERR: $m" -ForegroundColor Red; exit 1 }
# UTF-8 without BOM (PS 5.1 Set-Content -Encoding UTF8 writes a BOM, which breaks the Python addon)
function WriteNoBom($path, $text) {
  [IO.File]::WriteAllText($path, $text, [Text.UTF8Encoding]::new($false))
}
# UTF-8 WITH BOM, for .ps1 files: PowerShell 5.1 reads a .ps1 without a BOM as ANSI, so
# Cyrillic in the profile path turns into garbage
function WriteBom($path, $text) {
  [IO.File]::WriteAllText($path, $text, [Text.UTF8Encoding]::new($true))
}
# OEM code page of the console (the one cmd.exe uses when reading a .cmd)
function Get-OemEncoding {
  $codePage = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Nls\CodePage' -ErrorAction SilentlyContinue).OEMCP
  # OEMCP 65001 ("Unicode UTF-8" enabled in regional settings): GetEncoding would return
  # an encoding with a BOM, and cmd.exe does not understand a BOM at the start of a .cmd ("@echo off" breaks)
  if ($codePage -eq 65001) { return [Text.UTF8Encoding]::new($false) }
  if ($codePage) { try { return [Text.Encoding]::GetEncoding([int]$codePage) } catch {} }
  return [Text.Encoding]::ASCII
}
# contents of a Python string literal (double-quoted): \ and " are escaped,
# otherwise "C:\Users\..." gives a SyntaxError (\U starts a unicode escape)
function ConvertTo-PyLiteral($text) { return $text.Replace('\', '\\').Replace('"', '\"') }

# --- python ----------------------------------------------------------------
# We deliberately do not use "py -3": the launcher sometimes passes -3 to python.exe
# as a script argument (seen in CI) and breaks the venv; python/python3 cover everything.
# mitmproxy 12.x requires python >=3.12, <3.14: on 3.14 pip silently installs a broken
# environment, so we pick only a suitable version.
$py = $null
foreach ($c in @("python3", "python")) {
  try {
    $v = & $c --version 2>$null
    if (-not $?) { continue }
    if ($v -match "Python (3\.12|3\.13)\.") { $py = $c; break }
    if (-not $script:pyWarn) {
      Say "$v is not suitable (3.12/3.13 required for mitmproxy) — looking further"
      $script:pyWarn = $true
    }
  } catch {}
}
if (-not $py) { Die "Python 3.12 or 3.13 not found. Install it from python.org (tick 'Add to PATH') and re-run." }
Say "Python: $(& $py --version)"

# --- venv + mitmproxy ------------------------------------------------------
Say "1/6 venv + mitmproxy (pinned version, system untouched)"
New-Item -ItemType Directory -Force -Path $PREFIX, $CA_DIR | Out-Null
# PYTHONPATH from the environment (CI, activated venvs, IDEs) poisons the venv — clear it
Remove-Item Env:PYTHONPATH -ErrorAction SilentlyContinue
$venvDir  = Join-Path $PREFIX "venv"
$venvMitm = Join-Path $venvDir "Scripts\mitmdump.exe"
$venvPrev = "$venvDir.prev"
$pinVersion = $PIN.Split("=")[-1]
# output of "mitmdump --version" as text plus its exit status. "Continue" is local to the
# function: under "Stop", Windows PowerShell 5.1 turns the first redirected stderr line
# into a terminating error and the real message (e.g. ModuleNotFoundError) is lost
function Invoke-MitmVersion {
  $ErrorActionPreference = "Continue"
  if (-not (Test-Path -LiteralPath $venvMitm)) { return @{ Ok = $false; Text = "mitmdump.exe is missing" } }
  try {
    $text = (& $venvMitm --version 2>&1 | ForEach-Object { "$_" }) -join "`n"
    return @{ Ok = ($LASTEXITCODE -eq 0); Text = $text }
  } catch { return @{ Ok = $false; Text = "$_" } }
}
# exact "Mitmproxy: X.Y.Z" line: a substring would accept 12.3.10 for 12.3.1
function Test-MitmWorks {
  $r = Invoke-MitmVersion
  return ($r.Ok -and ($r.Text -match "(?m)^Mitmproxy:\s*$([regex]::Escape($pinVersion))\s*$"))
}
# OUR proxy copies only (re-install); a running mitmdump.exe locks the venv files
function Stop-OurProxy {
  Get-CimInstance Win32_Process -Filter "Name='mitmdump.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like "*$PREFIX*" } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
  Start-Sleep 1
}
# a failed rebuild puts the previous venv back: an outdated but working one must survive
function Stop-VenvSetup($message) {
  if (Test-Path -LiteralPath $venvPrev) {
    if (Test-Path -LiteralPath $venvDir) { Remove-Item -LiteralPath $venvDir -Recurse -Force -ErrorAction SilentlyContinue }
    Rename-Item -LiteralPath $venvPrev -NewName (Split-Path $venvDir -Leaf) -ErrorAction SilentlyContinue
  }
  Die $message
}
# a venv from a failed or older install is rebuilt, otherwise every re-run fails the same way.
# It is set aside, not deleted, until the new one works
if (Test-Path -LiteralPath $venvPrev) { Remove-Item -LiteralPath $venvPrev -Recurse -Force }
if ((Test-Path -LiteralPath $venvDir) -and -not (Test-MitmWorks)) {
  Say "the existing venv is broken or outdated - rebuilding it"
  Stop-OurProxy
  Rename-Item -LiteralPath $venvDir -NewName (Split-Path $venvPrev -Leaf)
}
if (-not (Test-Path -LiteralPath $venvMitm)) {
  & $py -m venv $venvDir
  if ($LASTEXITCODE -ne 0) { Stop-VenvSetup "failed to create venv" }
  $pip = Join-Path $venvDir "Scripts\pip.exe"
  & $pip install --quiet --upgrade pip
  & $pip install --quiet $PIN
  if ($LASTEXITCODE -ne 0) { Stop-VenvSetup "failed to install mitmproxy (check the network and access to pypi.org)" }
}
# catch "pip said OK but the environment is broken" (happened on python 3.14: no pyparsing)
if (-not (Test-MitmWorks)) {
  $why = ((Invoke-MitmVersion).Text -split "`n" | Select-Object -Last 2) -join " "
  Stop-VenvSetup "mitmproxy does not start with $(& $py --version): $why"
}
if (Test-Path -LiteralPath $venvPrev) { Remove-Item -LiteralPath $venvPrev -Recurse -Force -ErrorAction SilentlyContinue }

# --- addon -----------------------------------------------------------------
Say "2/6 Addon: strips ineligibleTiers from Google responses"
# addon.py is the single source of truth (in the repo next to install.ps1);
# on a pipe install it is not next to the script — download it from raw.githubusercontent
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$addonLocal = if ($PSScriptRoot) { Join-Path $PSScriptRoot "addon.py" } else { $null }
if ($addonLocal -and (Test-Path $addonLocal)) {
  $addonText = [IO.File]::ReadAllText($addonLocal)
} else {
  $addonUrl = if ($env:AGY_ADDON_URL) { $env:AGY_ADDON_URL } else { "$RAWBASE/addon.py" }
  try { $addonText = (iwr $addonUrl -UseBasicParsing).Content }
  catch { Die "failed to download addon.py ($addonUrl)" }
}
$addonText = $addonText.Replace("@@LOG@@", (ConvertTo-PyLiteral (Join-Path $PREFIX "mitm.log"))).Replace("@@VERBOSE_FLAG@@", (ConvertTo-PyLiteral (Join-Path $PREFIX "verbose.flag")))
if ($addonText -match "@@(LOG|VERBOSE_FLAG)@@") { Die "unsubstituted placeholders left in addon.py" }
WriteNoBom (Join-Path $PREFIX "addon.py") $addonText

# --- proxy runner ----------------------------------------------------------
$runPs1 = @"
& "$(Join-Path $PREFIX 'venv\Scripts\mitmdump.exe')" -s "$(Join-Path $PREFIX 'addon.py')" -p $PORT --set listen_host=127.0.0.1 --set "confdir=$CA_DIR" *>> "$(Join-Path $PREFIX 'mitm-stdout.log')"
"@
WriteBom (Join-Path $PREFIX "run-proxy.ps1") $runPs1

# --- autostart: HKCU Run (no admin) + immediate start ----------------------
Say "3/6 Proxy autostart (HKCU Run, port 127.0.0.1:$PORT)"
# stop OUR old proxy copies (re-install) — leave others alone
Stop-OurProxy

# is the port taken by something other than us? (after killing our copies it must be free)
# a real TCP probe instead of curl exit codes
function Test-PortBusy($p) {
  $c = New-Object System.Net.Sockets.TcpClient
  try {
    $iar = $c.BeginConnect("127.0.0.1", $p, $null, $null)
    if ($iar.AsyncWaitHandle.WaitOne(1500) -and $c.Connected) { return $true }
    return $false
  } catch { return $false } finally { $c.Close() }
}
if (Test-PortBusy $PORT) {
  Die "port $PORT is in use by something else; run with another port: `$env:AGY_BYPASS_PORT='8081'; powershell -File install.ps1"
}

$runCmd = "powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PREFIX\run-proxy.ps1`""
New-Item -Path $RUNKEY -Force | Out-Null   # the Run key may be missing on stripped-down profiles
Set-ItemProperty -Path $RUNKEY -Name "agy-region-fixer" -Value $runCmd
Start-Process powershell.exe -ArgumentList @("-WindowStyle","Hidden","-ExecutionPolicy","Bypass","-File","`"$PREFIX\run-proxy.ps1`"") -WindowStyle Hidden

# wait for the CA
$ca = Join-Path $CA_DIR "mitmproxy-ca-cert.pem"
$ok = $false
for ($i=0; $i -lt 40; $i++) {
  if (Test-Path $ca) { $ok = $true; break }
  Start-Sleep 1
}
if (-not $ok) { Die "CA was not generated — log: $PREFIX\mitm-stdout.log" }

# MITM check
$mitmOk = $false
for ($i=0; $i -lt 20; $i++) {
  curl.exe -s --max-time 5 --cacert $ca -x "http://127.0.0.1:$PORT" -o NUL https://www.google.com/
  if ($LASTEXITCODE -eq 0) { $mitmOk = $true; break }
  Start-Sleep 1
}
if ($mitmOk) { Say "proxy is alive, MITM works" } else { Say "MITM check failed — continuing (check $PREFIX\mitm-stdout.log later)" }

# --- shim ------------------------------------------------------------------
Say "4/6 Shim for agy (agy.cmd + agy.real.exe)"
function Get-ShimContent($port, $caPath) {
  # setlocal: proxy variables must not stay in the cmd.exe session after the CLI exits
  return @"
@echo off
setlocal
REM agy-region-fixer-shim
curl.exe -s --noproxy * -o nul --max-time 1 http://127.0.0.1:$port/
if not errorlevel 1 (
  set "SSL_CERT_FILE=$caPath"
  set "HTTPS_PROXY=http://127.0.0.1:$port"
)
"%~dp0agy.real.exe" %*
"@
}
# cmd.exe reads a .cmd in the OEM code page, not UTF-8 and not ASCII: Cyrillic
# in the profile path would otherwise turn into "?". The finished shim text is kept as a template —
# install and heal copy it byte for byte
$oem = Get-OemEncoding
$shimText = (Get-ShimContent $PORT $ca) -replace "`r?`n", "`r`n"
if ($oem.GetString($oem.GetBytes($shimText)) -ne $shimText) {
  Say "WARNING: the CA path contains characters outside the cmd.exe OEM encoding ($($oem.WebName)) — the shim may not find the certificate; install from a profile with a plain path"
}
$shimTpl = Join-Path $PREFIX "agy.cmd.tpl"
[IO.File]::WriteAllText($shimTpl, $shimText, $oem)
function Save-ShimPath($path) {
  # UTF-8 with BOM: PowerShell 5.1 reads such a file (Get-Content -Encoding UTF8) without loss
  WriteBom (Join-Path $PREFIX "shim.path") ($path + "`r`n")
}
$cmd = Get-Command agy -ErrorAction SilentlyContinue
$shimPath = $null
if ($cmd -and $cmd.Source -like "*.exe") {
  $agyExe = $cmd.Source
  $shimDir = Split-Path $agyExe
  $shimPath = Join-Path $shimDir "agy.cmd"
  $realExe  = Join-Path $shimDir "agy.real.exe"
  if (Test-Path -LiteralPath $realExe) { Remove-Item -LiteralPath $realExe -Force }
  Move-Item -LiteralPath $agyExe -Destination $realExe -Force
  Copy-Item -LiteralPath $shimTpl -Destination $shimPath -Force
  Save-ShimPath $shimPath
  Say "shim installed: $shimPath (real binary -> agy.real.exe)"
} elseif ($cmd -and $cmd.Source -like "*.cmd" -and (Select-String -LiteralPath $cmd.Source -Pattern "agy-region-fixer" -Quiet)) {
  # already our shim — refresh its contents (port/CA may have changed)
  Copy-Item -LiteralPath $shimTpl -Destination $cmd.Source -Force
  $shimPath = $cmd.Source
  Save-ShimPath $shimPath
  Say "shim updated: $shimPath"
} else {
  Say "agy not found in PATH — shim not installed. Install Antigravity CLI and re-run the installer."
}

# --- heal ------------------------------------------------------------------
Say "5/6 Shim self-healing (task every 5 minutes)"
$healPs1 = @'
$ErrorActionPreference = "Continue"
$PREFIX = '@PREFIX@'
$log          = Join-Path $PREFIX "mitm.log"
$shimPathFile = Join-Path $PREFIX "shim.path"
$shimTpl      = Join-Path $PREFIX "agy.cmd.tpl"
function Write-HealLog($message) { Add-Content -LiteralPath $log -Value $message -Encoding UTF8 }
function Restore-Shim($path) { Copy-Item -LiteralPath $shimTpl -Destination $path -Force }
if ((Test-Path -LiteralPath $shimPathFile) -and (Test-Path -LiteralPath $shimTpl)) {
  $shimPath = (Get-Content -LiteralPath $shimPathFile -Encoding UTF8 -First 1).Trim()
  $shimDir  = Split-Path $shimPath
  $realExe  = Join-Path $shimDir "agy.real.exe"
  $agyExe   = Join-Path $shimDir "agy.exe"
  if (-not (Test-Path -LiteralPath $shimPath) -or -not (Select-String -LiteralPath $shimPath -Pattern "agy-region-fixer" -Quiet)) {
    Restore-Shim $shimPath
    Write-HealLog "[heal] restored $shimPath"
  }
  # a CLI update brought agy.exe back -> hide it again and restore agy.cmd
  if ((Test-Path -LiteralPath $agyExe) -and (Test-Path -LiteralPath $realExe)) {
    # wait for the size to stabilize (cap ~30 s): a mv in the middle of a write leaves a broken agy.real.exe.
    # not stabilized — bail out, the task will retry in 5 minutes.
    $prev = -1L; $len = -1L; $stable = $false
    for ($i=0; $i -lt 15; $i++) {
      try { $len = (Get-Item -LiteralPath $agyExe -Force).Length } catch { break }
      if ($len -eq $prev) { $stable = $true; break }
      $prev = $len; Start-Sleep 2
    }
    if (-not $stable) {
      Write-HealLog "[heal] agy.exe is still being written (size=$len) - left as is"
    } else {
      # validation: a real binary starts with MZ and is >= 10 MB; an incomplete update is left alone
      $looksReal = $false
      try {
        $fs = [IO.File]::OpenRead($agyExe)
        try {
          $m = New-Object byte[] 2
          [void]$fs.Read($m, 0, 2)
          $looksReal = ($m[0] -eq 0x4D -and $m[1] -eq 0x5A) -and ($fs.Length -ge 10MB)
        } finally { $fs.Close() }
      } catch { $looksReal = $false }
      if ($looksReal) {
        Remove-Item -LiteralPath $realExe -Force
        Move-Item -LiteralPath $agyExe -Destination $realExe -Force
        Restore-Shim $shimPath
        Write-HealLog "[heal] restored after CLI update $shimPath"
      } else {
        Write-HealLog "[heal] suspicious agy.exe (not MZ or <10MB) - left as is"
      }
    }
  }
}
'@
$healPs1 = $healPs1.Replace("@PREFIX@", $PREFIX.Replace("'", "''"))
WriteBom (Join-Path $PREFIX "heal.ps1") $healPs1
# /TR is passed as ONE ready-made argument string via Start-Process: this way the quotes around
# a path with a space (C:\Users\John Doe) reach schtasks the same in Windows PowerShell
# 5.1 and PowerShell 7 (with normal native argument passing they are lost in 5.1).
# Nested quotes in /TR are escaped as \" — schtasks requires that.
$healAction = "powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -File \`"$PREFIX\heal.ps1\`""
$schtasksArgs = "/Create /F /TN agy-region-fixer-heal /SC MINUTE /MO 5 /TR `"$healAction`""
$schtasksProc = Start-Process -FilePath "schtasks.exe" -ArgumentList $schtasksArgs -NoNewWindow -Wait -PassThru
if ($schtasksProc.ExitCode -ne 0) {
  Say "WARNING: the heal task was not created (run the installer as administrator or restore the shim manually: powershell $PREFIX\heal.ps1)"
}

# --- uninstall -------------------------------------------------------------
Say "6/6 Uninstall script"
$unPs1 = @'
$ErrorActionPreference = "Continue"
$PREFIX = '@PREFIX@'
Remove-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" -Name "agy-region-fixer" -ErrorAction SilentlyContinue
schtasks /Delete /F /TN "agy-region-fixer-heal" 2>$null
Get-CimInstance Win32_Process -Filter "Name='mitmdump.exe'" -ErrorAction SilentlyContinue |
  Where-Object { $_.CommandLine -like "*$PREFIX*" } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
$shimPathFile = Join-Path $PREFIX "shim.path"
if (Test-Path -LiteralPath $shimPathFile) {
  $shimPath = (Get-Content -LiteralPath $shimPathFile -Encoding UTF8 -First 1).Trim()
  $shimDir  = Split-Path $shimPath
  $realExe  = Join-Path $shimDir "agy.real.exe"
  if (Test-Path -LiteralPath $realExe) {
    Move-Item -LiteralPath $realExe -Destination (Join-Path $shimDir "agy.exe") -Force
    Write-Host "restored: agy.exe"
  }
  Remove-Item -LiteralPath $shimPath -Force -ErrorAction SilentlyContinue
}
Remove-Item -Recurse -Force -LiteralPath $PREFIX -ErrorAction SilentlyContinue
Write-Host "Fully removed."
'@
$unPs1 = $unPs1.Replace("@PREFIX@", $PREFIX.Replace("'", "''"))
WriteBom (Join-Path $PREFIX "uninstall.ps1") $unPs1

# --- smoke -----------------------------------------------------------------
# hard 120 s limit: the process is started separately and the whole tree is killed on timeout
# (agy.cmd -> cmd.exe -> agy.real.exe); otherwise a hung request or a wait for login
# would block the install forever
$SMOKE_TIMEOUT_MS = 120000
$smokeCmd = Get-Command agy -ErrorAction SilentlyContinue
if ($smokeCmd) {
  Say "Smoke test: agy -p (up to 120 s)"
  $smokeOut = [IO.Path]::GetTempFileName()
  $smokeErr = [IO.Path]::GetTempFileName()
  try {
    $proc = Start-Process -FilePath $smokeCmd.Source -ArgumentList @("-p", "`"Reply exactly: BYPASS_OK`"") `
      -NoNewWindow -PassThru -RedirectStandardOutput $smokeOut -RedirectStandardError $smokeErr
    if ($proc.WaitForExit($SMOKE_TIMEOUT_MS)) {
      # stdout first: the model's answer is there; stderr is only a fallback source for the message
      $outLines = @(Get-Content -LiteralPath $smokeOut -ErrorAction SilentlyContinue | Where-Object { $_ })
      $errLines = @(Get-Content -LiteralPath $smokeErr -ErrorAction SilentlyContinue | Where-Object { $_ })
      $hit = @($outLines + $errLines | Where-Object { $_ -like "*BYPASS_OK*" }) | Select-Object -First 1
      if ($hit) { Say "OK — model replied: $hit — bypass works" }
      else {
        $last = @($outLines + $errLines) | Select-Object -Last 1
        Say "agy did not reply BYPASS_OK: $last (did you log in? log: $PREFIX\mitm.log)"
      }
    } else {
      taskkill /T /F /PID $proc.Id 2>&1 | Out-Null
      Say "smoke did not finish in 120 s — aborted (did you log in? log: $PREFIX\mitm.log)"
    }
  } catch { Say "smoke failed: $_" }
  finally { Remove-Item -LiteralPath $smokeOut, $smokeErr -Force -ErrorAction SilentlyContinue }
}

Say "Done. Proxy: 127.0.0.1:$PORT | log: $PREFIX\mitm.log | uninstall: powershell $PREFIX\uninstall.ps1"
exit 0   # a successful install always returns 0; a smoke warning must not fail the exit code
