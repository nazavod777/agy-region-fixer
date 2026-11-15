# ============================================================================
# agy-region-fixer — Antigravity CLI region bypass, Windows installer
# Requirements: Windows 10/11, Python 3.12 or 3.13 from python.org (tick
#             "Add to PATH"; mitmproxy 12.x does not support 3.14+ or <3.12),
#             an installed and logged-in Antigravity CLI (run agy login beforehand).
# Administrator rights are NOT needed (HKCU proxy autostart and user tasks).
#
# Install:    powershell -ExecutionPolicy Bypass -File install.ps1
# Custom port: $env:AGY_BYPASS_PORT=8081; powershell ... install.ps1
# Uninstall:  powershell -ExecutionPolicy Bypass -File $HOME\.agy-region-fixer\uninstall.ps1
#
# How it works: a local MITM proxy (mitmproxy) strips ineligibleTiers
# from Google loadCodeAssist responses. The agy.exe binary is NOT modified.
# The native agy.exe shim supports binaries and managed launchers and is healed
# on filesystem events, with a five-minute fallback after CLI updates.
#
# The proxy addon lives in addon.py next to this script (in the repo); for a
# pipe install (iex (irm ...)) it is downloaded from raw.githubusercontent.com
# (override with $env:AGY_ADDON_URL).
# ============================================================================
$ErrorActionPreference = "Stop"
$PREFIX  = Join-Path $env:USERPROFILE ".agy-region-fixer"
$PORT    = $null
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
# contents of a Python string literal (double-quoted): \ and " are escaped,
# otherwise "C:\Users\..." gives a SyntaxError (\U starts a unicode escape)
function ConvertTo-PyLiteral($text) { return $text.Replace('\', '\\').Replace('"', '\"') }

# Only ASCII decimal digits are accepted; normalize zeros before converting so
# even an overlong value cannot overflow or become part of generated commands.
function ConvertTo-ProxyPort([string]$value) {
  if ($value -cnotmatch '\A[0-9]+\z') { throw "AGY_BYPASS_PORT must be an ASCII decimal integer from 1 to 65535" }
  $normalized = $value.TrimStart('0')
  if (-not $normalized -or $normalized.Length -gt 5) { throw "AGY_BYPASS_PORT must be an ASCII decimal integer from 1 to 65535" }
  $number = [int]$normalized
  if ($number -gt 65535) { throw "AGY_BYPASS_PORT must be an ASCII decimal integer from 1 to 65535" }
  return $number
}
function Test-PortBindable($port) {
  $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $port)
  try {
    $listener.Server.ExclusiveAddressUse = $true
    $listener.Start()
    return $true
  } catch [Net.Sockets.SocketException] { return $false }
  finally { $listener.Stop() }
}
function Select-ProxyPort($requestedPort, $savedPortPath) {
  if ($null -ne $requestedPort) {
    if (-not (Test-PortBindable $requestedPort)) {
      throw "port $requestedPort cannot be bound on 127.0.0.1; choose another AGY_BYPASS_PORT or leave it unset for automatic selection"
    }
    return $requestedPort
  }
  if (Test-Path -LiteralPath $savedPortPath) {
    $savedText = Get-Content -LiteralPath $savedPortPath -Encoding UTF8 -First 1
    try { $savedPort = ConvertTo-ProxyPort $savedText }
    catch { $savedPort = $null }
    if ($savedPort -ge 49152 -and (Test-PortBindable $savedPort)) { return $savedPort }
  }
  $maxAttempts = 32
  for ($attempt = 0; $attempt -lt $maxAttempts; $attempt++) {
    $candidate = Get-Random -Minimum 49152 -Maximum 65536
    if (Test-PortBindable $candidate) { return $candidate }
  }
  throw "could not find a bindable localhost TCP port from 49152 to 65535 after $maxAttempts attempts; set AGY_BYPASS_PORT explicitly"
}
# Reject invalid configuration before any proxy process can be stopped.
if (-not [string]::IsNullOrEmpty($env:AGY_BYPASS_PORT)) {
  try { $PORT = ConvertTo-ProxyPort $env:AGY_BYPASS_PORT }
  catch { Die $_.Exception.Message }
}

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
$venvPython = Join-Path $venvDir "Scripts\python.exe"
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
  # Legacy console launcher and the isolated Python entrypoint have distinct
  # ownership checks. An unrelated Python process must never be stopped.
  Get-CimInstance Win32_Process -Filter "Name='mitmdump.exe' OR Name='python.exe'" -OperationTimeoutSec 5 -ErrorAction SilentlyContinue |
    Where-Object {
      if ($_.ExecutablePath -eq $venvMitm) { return $true }
      if ($_.ExecutablePath -notmatch '(?i)[\\/]python\.exe$') { return $false }
      $pythonPath = Join-Path (Split-Path -Parent $venvMitm) 'python.exe'
      if ($_.ExecutablePath -ine $pythonPath -or -not $_.CommandLine) { return $false }
      if (-not ('AgyProxyCommandLine' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class AgyProxyCommandLine {
    [DllImport("shell32.dll", SetLastError = true)] static extern IntPtr CommandLineToArgvW([MarshalAs(UnmanagedType.LPWStr)] string command, out int count);
    [DllImport("kernel32.dll")] static extern IntPtr LocalFree(IntPtr memory);
    public static string[] Parse(string command) {
        int count;
        IntPtr memory = CommandLineToArgvW(command, out count);
        if (memory == IntPtr.Zero) throw new InvalidOperationException("Cannot parse the proxy command line.");
        try {
            var result = new string[count];
            for (int index = 0; index < count; index++) result[index] = Marshal.PtrToStringUni(Marshal.ReadIntPtr(memory, index * IntPtr.Size));
            return result;
        } finally { LocalFree(memory); }
    }
}
'@ -ErrorAction Stop
      }
      try {
        $arguments = [AgyProxyCommandLine]::Parse($_.CommandLine)
        $addonPath = Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $venvMitm))) 'addon.py'
        $validCustom = $arguments.Count -eq 7 -or ($arguments.Count -eq 9 -and $arguments[7] -ceq '--addon' -and
          [IO.Path]::IsPathRooted($arguments[8]) -and [IO.Path]::GetFullPath($arguments[8]) -ieq (Join-Path (Split-Path -Parent $addonPath) 'custom-addon.py'))
        return $validCustom -and $arguments[0] -ieq $pythonPath -and $arguments[1] -ceq '-I' -and
          [IO.Path]::IsPathRooted($arguments[2]) -and [IO.Path]::GetFullPath($arguments[2]) -ieq $addonPath -and
          $arguments[3] -ceq '--port' -and $arguments[4] -cmatch '\A[0-9]{1,5}\z' -and
          [int]$arguments[4] -ge 1 -and [int]$arguments[4] -le 65535 -and $arguments[5] -ceq '--confdir' -and
          [IO.Path]::IsPathRooted($arguments[6]) -and [IO.Path]::GetFullPath($arguments[6]) -ieq (Join-Path (Split-Path -Parent $addonPath) 'ca')
      } catch { return $false }
    } |
    ForEach-Object {
      Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
      Wait-Process -Id $_.ProcessId -Timeout 5 -ErrorAction SilentlyContinue
    }
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
  $addonUrl = "$RAWBASE/addon.py"
  try { $addonText = (iwr $addonUrl -UseBasicParsing -TimeoutSec 30).Content }
  catch { Die "failed to download addon.py ($addonUrl)" }
}
$addonText = $addonText.Replace("@@LOG@@", (ConvertTo-PyLiteral (Join-Path $PREFIX "mitm.log"))).Replace("@@VERBOSE_FLAG@@", (ConvertTo-PyLiteral (Join-Path $PREFIX "verbose.flag")))
if ($addonText -match "@@(LOG|VERBOSE_FLAG)@@") { Die "unsubstituted placeholders left in addon.py" }
WriteNoBom (Join-Path $PREFIX "addon.py") $addonText
$customAddonArgument = ''
if ($env:AGY_ADDON_URL) {
  try { $customText = (iwr $env:AGY_ADDON_URL -UseBasicParsing -TimeoutSec 30).Content }
  catch { Die "failed to download custom addon.py ($env:AGY_ADDON_URL)" }
  $customText = $customText.Replace("@@LOG@@", (ConvertTo-PyLiteral (Join-Path $PREFIX "mitm.log"))).Replace("@@VERBOSE_FLAG@@", (ConvertTo-PyLiteral (Join-Path $PREFIX "verbose.flag")))
  if ($customText -match "@@(LOG|VERBOSE_FLAG)@@") { Die "unsubstituted placeholders left in custom addon.py" }
  WriteNoBom (Join-Path $PREFIX 'custom-addon.py') $customText
  $customAddonArgument = ' --addon "' + (Join-Path $PREFIX 'custom-addon.py') + '"'
}


# Stop our previous proxy before checking whether its saved port can be reused.
Stop-OurProxy
try { $PORT = Select-ProxyPort $PORT (Join-Path $PREFIX "port") }
catch { Die $_.Exception.Message }
WriteNoBom (Join-Path $PREFIX "port") ("$PORT`r`n")
Say "Proxy port: 127.0.0.1:$PORT"

# --- proxy runner ----------------------------------------------------------
$runPs1 = @"
& "$(Join-Path $PREFIX 'venv\Scripts\python.exe')" -I "$(Join-Path $PREFIX 'addon.py')" --port $PORT --confdir "$CA_DIR"$customAddonArgument *>> "$(Join-Path $PREFIX 'mitm-stdout.log')"
"@
WriteBom (Join-Path $PREFIX "run-proxy.ps1") $runPs1

# --- autostart: HKCU Run (no admin) + immediate start ----------------------
Say "3/6 Proxy autostart (HKCU Run, port 127.0.0.1:$PORT)"
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
# The local CA has no online revocation service. Schannel still verifies the
# certificate chain; only unavailable revocation distribution points are ignored.
$mitmOk = $false
for ($i=0; $i -lt 20; $i++) {
  curl.exe -s --ssl-revoke-best-effort --max-time 5 --cacert $ca -x "http://127.0.0.1:$PORT" -o NUL https://www.google.com/
  if ($LASTEXITCODE -eq 0) { $mitmOk = $true; break }
  Start-Sleep 1
}
if ($mitmOk) { Say "proxy is alive, MITM works" } else { Say "MITM check failed — continuing (check $PREFIX\mitm-stdout.log later)" }

# The native launcher and its lifecycle helpers are embedded: this installer is
# the only Windows entrypoint for every supported CLI installation format.
$windowsSupportSource = @'
# Windows PowerShell 5.1 support for the native agy launcher. Dot-source only.

function Test-AgyNativeShim {
  param([Parameter(Mandatory = $true)][string]$Path)
  # App Execution Aliases can be zero-length reparse points, not readable PE files.
  if ($Path -match '(?i)[\\/]WindowsApps[\\/]') { return $false }
  if (-not [IO.File]::Exists($Path)) { return $false }
  try {
    return [Diagnostics.FileVersionInfo]::GetVersionInfo($Path).FileDescription -ceq 'agy-region-fixer-native-shim-v1'
  } catch { return $false }
}

function Get-AgyFullPath {
  param([string]$Path)
  if ([string]::IsNullOrWhiteSpace($Path) -or -not [IO.Path]::IsPathRooted($Path)) {
    throw "An absolute path is required: $Path"
  }
  return [IO.Path]::GetFullPath($Path)
}

function Test-AgySamePath {
  param([string]$Left, [string]$Right)
  return [string]::Equals([IO.Path]::GetFullPath($Left).TrimEnd('\', '/'), [IO.Path]::GetFullPath($Right).TrimEnd('\', '/'), [StringComparison]::OrdinalIgnoreCase)
}

function Assert-AgyRegularFile {
  param([string]$Path)
  if ([IO.File]::Exists($Path)) {
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
      throw "Refusing to replace a linked file: $Path"
    }
  } elseif ([IO.Directory]::Exists($Path)) { throw "Expected a file, found a directory: $Path" }
}

function Assert-AgyUnlinkedPath {
  param([string]$Path)
  $current = Get-AgyFullPath $Path
  while ($current) {
    $item = Get-Item -LiteralPath $current -Force -ErrorAction SilentlyContinue
    if ($item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Refusing a linked shim path: $current" }
    $parent = Split-Path -Parent $current
    if ($parent -eq $current) { break }
    $current = $parent
  }
}

function Invoke-AgyShimLock {
  param([string]$Prefix, [scriptblock]$Action)
  $Prefix = Get-AgyFullPath $Prefix
  if (-not [IO.Directory]::Exists($Prefix)) { throw "Installation directory does not exist: $Prefix" }
  Assert-AgyUnlinkedPath $Prefix
  $lockPath = Join-Path $Prefix 'shim.lock'
  Assert-AgyUnlinkedPath $lockPath
  Assert-AgyRegularFile $lockPath
  $watch = [Diagnostics.Stopwatch]::StartNew()
  $lock = $null
  while ($null -eq $lock) {
    try { $lock = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
    catch [IO.IOException] {
      if ($watch.ElapsedMilliseconds -ge 10000) { throw "Timed out after 10 seconds waiting for the shim lock: $lockPath" }
      Start-Sleep -Milliseconds 100
    }
  }
  try { & $Action $Prefix }
  finally { $lock.Dispose() }
}

function Get-AgyUniquePath {
  param([string]$Path, [string]$Role = 'stage')
  return "$Path.agy-$Role-$([Guid]::NewGuid().ToString('N'))"
}

function New-AgyTransaction {
  return [pscustomobject]@{ Changes = (New-Object 'Collections.Generic.List[object]'); Temps = (New-Object 'Collections.Generic.List[string]'); ExpectedHashes = @{}; Committed = $false }
}

function New-AgyStagedCopy {
  param($Transaction, [string]$Source, [string]$Destination)
  Assert-AgyUnlinkedPath $Source
  Assert-AgyUnlinkedPath $Destination
  $stage = Get-AgyUniquePath $Destination
  $Transaction.Temps.Add($stage)
  [IO.File]::Copy($Source, $stage, $false)
  return $stage
}

function New-AgyStagedJson {
  param($Transaction, [string]$Destination, $Value)
  $stage = Get-AgyUniquePath $Destination
  $Transaction.Temps.Add($stage)
  [IO.File]::WriteAllText($stage, ($Value | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false)))
  return $stage
}

function Set-AgyTransactionFile {
  param($Transaction, [string]$Path, [string]$Stage)
  Assert-AgyUnlinkedPath $Path
  Assert-AgyRegularFile $Path
  $exists = [IO.File]::Exists($Path)
  $backup = Get-AgyUniquePath $Path 'rollback'
  if ($exists) { [IO.File]::Replace($Stage, $Path, $backup) }
  else { [IO.File]::Move($Stage, $Path) }
  $Transaction.Changes.Add([pscustomobject]@{ Path = $Path; Backup = $backup; Existed = $exists })
  if ($Transaction.ExpectedHashes.ContainsKey($Path)) {
    if (-not $exists -or (Get-FileHash -LiteralPath $backup -Algorithm SHA256).Hash -cne $Transaction.ExpectedHashes[$Path]) {
      throw "The original changed during repair; the transaction will be rolled back: $Path"
    }
  }
}

function Remove-AgyTransactionFile {
  param($Transaction, [string]$Path)
  Assert-AgyUnlinkedPath $Path
  Assert-AgyRegularFile $Path
  if (-not [IO.File]::Exists($Path)) { return }
  $backup = Get-AgyUniquePath $Path 'rollback'
  [IO.File]::Move($Path, $backup)
  $Transaction.Changes.Add([pscustomobject]@{ Path = $Path; Backup = $backup; Existed = $true })
}

function Complete-AgyTransaction {
  param($Transaction)
  $Transaction.Committed = $true
  foreach ($change in $Transaction.Changes) {
    if ([IO.File]::Exists($change.Backup)) { [IO.File]::Delete($change.Backup) }
  }
}

function Undo-AgyTransaction {
  param($Transaction)
  if ($Transaction.Committed) { return }
  $failures = New-Object 'Collections.Generic.List[string]'
  for ($i = $Transaction.Changes.Count - 1; $i -ge 0; $i--) {
    $change = $Transaction.Changes[$i]
    try {
      if ($change.Existed) {
        if ([IO.File]::Exists($change.Path)) { [IO.File]::Replace($change.Backup, $change.Path, [NullString]::Value) }
        else { [IO.File]::Move($change.Backup, $change.Path) }
      } elseif ([IO.File]::Exists($change.Path)) { [IO.File]::Delete($change.Path) }
    } catch { $failures.Add("$($change.Path): $($_.Exception.Message)") }
  }
  if ($failures.Count) { throw "Shim rollback failed; recovery copies were preserved. $($failures -join '; ')" }
}

function Clear-AgyTransactionTemps {
  param($Transaction)
  foreach ($path in $Transaction.Temps) {
    if ([IO.File]::Exists($path)) { [IO.File]::Delete($path) }
  }
}

function Undo-AgyFailedOperation {
  param($Transaction, $Failure, [bool]$RestorePaths = $false, [AllowNull()][string]$UserPath, [AllowNull()][string]$ProcessPath)
  $failures = New-Object 'Collections.Generic.List[string]'
  if (-not $Transaction.Committed) {
    if ($RestorePaths) {
      try { Set-AgyUserPath -Value $UserPath }
      catch { $failures.Add("User PATH: $($_.Exception.Message)") }
      try { $env:Path = $ProcessPath }
      catch { $failures.Add("Process PATH: $($_.Exception.Message)") }
    }
    # A registry failure must never prevent restoring the executable and its backup.
    try { Undo-AgyTransaction $Transaction }
    catch { $failures.Add($_.Exception.Message) }
  }
  if ($failures.Count) { throw "Shim operation failed: $($Failure.Exception.Message). Recovery also failed: $($failures -join '; ')" }
  throw $Failure
}

function Read-AgyJson {
  param([string]$Path)
  if ((Get-Item -LiteralPath $Path -Force -ErrorAction Stop).Length -gt 65536) { throw "Shim configuration is too large: $Path" }
  try { return [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop }
  catch { throw "Cannot read shim configuration ${Path}: $($_.Exception.Message)" }
}

function Read-AgyLauncherConfig {
  param([string]$Path)
  Assert-AgyUnlinkedPath $Path
  $config = Read-AgyJson $Path
  if ($config.version -ne 1 -or @('exe', 'cmd', 'ps1') -notcontains $config.kind -or ($config.port -isnot [int] -and $config.port -isnot [long]) -or $config.port -lt 1 -or $config.port -gt 65535) {
    throw "Unsupported launcher configuration: $Path"
  }
  $config.target = Get-AgyFullPath $config.target
  $config.certificate = Get-AgyFullPath $config.certificate
  return $config
}

function Read-AgyShimState {
  param([string]$Prefix)
  $path = Join-Path $Prefix 'shim-state.json'
  Assert-AgyUnlinkedPath $path
  if (-not [IO.File]::Exists($path)) { return $null }
  $state = Read-AgyJson $path
  if ($state.version -ne 1 -or @('inplace', 'overlay') -notcontains $state.mode -or @('exe', 'cmd', 'ps1') -notcontains $state.kind) {
    throw "Unsupported shim state: $path"
  }
  $defaults = @{ pathAdded = $false; processPathAdded = $false; pathEntry = $null; sourceHash = $null; legacyPath = $null }
  foreach ($name in $defaults.Keys) {
    if ($null -eq $state.PSObject.Properties[$name]) { $state | Add-Member -NotePropertyName $name -NotePropertyValue $defaults[$name] }
  }
  $state.shimPath = Get-AgyFullPath $state.shimPath
  $state.target = Get-AgyFullPath $state.target
  if ($state.mode -eq 'inplace') {
    $real = Join-Path (Split-Path -Parent $state.shimPath) 'agy.real.exe'
    if ($state.kind -ne 'exe' -or -not (Test-AgySamePath $state.target $real) -or [IO.Path]::GetFileName($state.shimPath) -ine 'agy.exe') {
      throw "Invalid in-place shim state: $path"
    }
  } else {
    if (-not (Test-AgySamePath $state.shimPath (Join-Path $Prefix 'bin\agy.exe')) -or (Test-AgySamePath $state.target $state.shimPath)) {
      throw "Invalid overlay shim state: $path"
    }
    if (-not $state.pathEntry) { $state.pathEntry = Join-Path $Prefix 'bin' }
    if (-not (Test-AgySamePath $state.pathEntry (Join-Path $Prefix 'bin'))) {
      throw "Invalid PATH ownership in shim state: $path"
    }
  }
  return $state
}

function Assert-AgyOwnedConfig {
  param($State)
  $path = Join-Path (Split-Path -Parent $State.shimPath) 'agy-launcher.json'
  if ([IO.File]::Exists($path)) {
    $config = Read-AgyLauncherConfig $path
    if (-not (Test-AgySamePath $config.target $State.target) -or $config.kind -cne $State.kind) {
      throw "Refusing to replace a foreign launcher configuration: $path"
    }
  }
  return $path
}

function Test-AgyLegacyShim {
  param([string]$Path)
  if (-not [IO.File]::Exists($Path) -or [IO.Path]::GetExtension($Path) -ine '.cmd') { return $false }
  $stream = [IO.File]::OpenRead($Path)
  try {
    $bytes = New-Object byte[] 8192
    $count = $stream.Read($bytes, 0, $bytes.Length)
    return [Text.Encoding]::ASCII.GetString($bytes, 0, $count) -match '(?im)^\s*REM agy-region-fixer-shim\s*$'
  } finally { $stream.Dispose() }
}

function Read-AgyLegacyState {
  param([string]$Prefix)
  $saved = Join-Path $Prefix 'shim.path'
  if (-not [IO.File]::Exists($saved)) { return $null }
  $path = Get-AgyFullPath (([IO.File]::ReadAllText($saved, [Text.Encoding]::UTF8) -split '\r?\n')[0].Trim())
  if (-not (Test-AgyLegacyShim $path)) { throw "The saved legacy shim is missing or is not owned: $path" }
  $dir = Split-Path -Parent $path
  $target = Join-Path $dir 'agy.real.exe'
  if (-not [IO.File]::Exists($target) -or (Test-AgyNativeShim $target)) { throw "The legacy original binary is missing or invalid: $target" }
  return [pscustomobject]@{ version = 1; mode = 'inplace'; shimPath = (Join-Path $dir 'agy.exe'); target = $target; kind = 'exe'; pathAdded = $false; pathEntry = $null; legacyPath = $path }
}

function Get-AgyCommandTarget {
  param([string]$Prefix)
  $overlay = Join-Path $Prefix 'bin\agy.exe'
  $commands = @(Get-Command agy -All -CommandType Application, ExternalScript -ErrorAction SilentlyContinue)
  foreach ($command in $commands) {
    $path = $command.Source
    if ([string]::IsNullOrWhiteSpace($path)) { $path = $command.Path }
    if ([string]::IsNullOrWhiteSpace($path)) { continue }
    $path = Get-AgyFullPath $path
    if ((Test-AgySamePath $path $overlay) -or (Test-AgyNativeShim $path)) { continue }
    $extension = [IO.Path]::GetExtension($path).ToLowerInvariant()
    if (@('.exe', '.cmd', '.ps1') -notcontains $extension -or (Test-AgyLegacyShim $path)) { continue }
    $kind = $extension.Substring(1)
    $managed = $path -match '(?i)[\\/]WindowsApps[\\/]' -or ($extension -eq '.exe' -and [IO.File]::Exists([IO.Path]::ChangeExtension($path, '.shim')))
    if ($kind -eq 'exe' -and -not $managed) {
      return [pscustomobject]@{ version = 1; mode = 'inplace'; shimPath = $path; target = (Join-Path (Split-Path -Parent $path) 'agy.real.exe'); kind = 'exe'; pathAdded = $false; pathEntry = $null }
    }
    return [pscustomobject]@{ version = 1; mode = 'overlay'; shimPath = $overlay; target = $path; kind = $kind; pathAdded = $false; pathEntry = (Join-Path $Prefix 'bin') }
  }
  throw 'agy was not found in PATH. Install Antigravity CLI and run the installer again.'
}

function Get-AgyUserPath { return [Environment]::GetEnvironmentVariable('Path', 'User') }
function Set-AgyUserPath { param([AllowNull()][string]$Value) [Environment]::SetEnvironmentVariable('Path', $Value, 'User') }

function Send-AgyEnvironmentChange {
  # Existing shells keep their own environment. This notifies Explorer and new apps.
  try {
    if (-not ('AgyEnvironmentNotification' -as [type])) {
      Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public static class AgyEnvironmentNotification { [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)] public static extern IntPtr SendMessageTimeout(IntPtr window, uint message, UIntPtr wParam, string lParam, uint flags, uint timeout, out UIntPtr result); }' -ErrorAction Stop
    }
    $result = [UIntPtr]::Zero
    [void][AgyEnvironmentNotification]::SendMessageTimeout([IntPtr]65535, 0x001A, [UIntPtr]::Zero, 'Environment', 2, 1000, [ref]$result)
  } catch { Write-Warning "Could not notify other applications about PATH: $($_.Exception.Message)" }
}

function Test-AgyPathEntry {
  param([string]$Entry, [string]$Path)
  if ([string]::IsNullOrWhiteSpace($Entry)) { return $false }
  try { return Test-AgySamePath ([Environment]::ExpandEnvironmentVariables($Entry.Trim().Trim('"'))) $Path }
  catch { return $false }
}

function Get-AgyPathWithoutEntry {
  param([AllowNull()][string]$Value, [string]$Entry)
  return (@($Value -split ';' | Where-Object { -not (Test-AgyPathEntry $_ $Entry) }) -join ';')
}

function Test-AgyPathContains {
  param([AllowNull()][string]$Value, [string]$Entry)
  return @($Value -split ';' | Where-Object { Test-AgyPathEntry $_ $Entry }).Count -gt 0
}

function Add-AgyOverlayPath {
  param($State)
  $entry = $State.pathEntry
  $userPath = Get-AgyUserPath
  $processPath = $env:Path
  if (-not (Test-AgyPathContains $userPath $entry)) { $State.pathAdded = $true }
  if (-not (Test-AgyPathContains $processPath $entry)) { $State | Add-Member -NotePropertyName processPathAdded -NotePropertyValue $true -Force }
  $nextUser = $entry
  $remainingUser = Get-AgyPathWithoutEntry $userPath $entry
  if ($remainingUser) { $nextUser += ';' + $remainingUser }
  if ($nextUser -cne $userPath) { Set-AgyUserPath -Value $nextUser }
  $remainingProcess = Get-AgyPathWithoutEntry $processPath $entry
  $env:Path = $entry
  if ($remainingProcess) { $env:Path += ';' + $remainingProcess }
}

function Get-AgyNativeTemplate {
  param([string]$Prefix, [string]$SourcePath, $State, $Transaction)
  $SourcePath = Get-AgyFullPath $SourcePath
  if (-not [IO.File]::Exists($SourcePath)) { throw "Native launcher source is missing: $SourcePath" }
  $sourceHash = (Get-FileHash -LiteralPath $SourcePath -Algorithm SHA256 -ErrorAction Stop).Hash
  $template = Join-Path $Prefix 'agy.exe.tpl'
  if ($State -and $State.PSObject.Properties['sourceHash'] -and $State.sourceHash -ceq $sourceHash -and (Test-AgyNativeShim $template)) {
    return [pscustomobject]@{ Path = $template; SourceHash = $sourceHash; Staged = $false }
  }
  if ([IO.File]::Exists($template) -and -not (Test-AgyNativeShim $template)) { throw "Refusing to replace a foreign launcher template: $template" }
  $compiler = $null
  foreach ($framework in @('Framework64', 'Framework')) {
    $candidate = Join-Path $env:WINDIR "Microsoft.NET\$framework\v4.0.30319\csc.exe"
    if ([IO.File]::Exists($candidate)) { $compiler = $candidate; break }
  }
  if (-not $compiler) { throw 'The Windows .NET Framework C# compiler was not found.' }
  $stage = Get-AgyUniquePath $template
  $Transaction.Temps.Add($stage)
  $arguments = '/nologo /target:exe /optimize+ /platform:anycpu /reference:System.Web.Extensions.dll /out:"' + $stage + '" "' + $SourcePath + '"'
  $startInfo = New-Object Diagnostics.ProcessStartInfo
  $startInfo.FileName = $compiler
  $startInfo.Arguments = $arguments
  $startInfo.UseShellExecute = $false
  $startInfo.CreateNoWindow = $true
  $startInfo.RedirectStandardOutput = $true
  $startInfo.RedirectStandardError = $true
  $process = New-Object Diagnostics.Process
  $process.StartInfo = $startInfo
  $processStarted = $false
  try {
    $processStarted = $process.Start()
    if (-not $processStarted) { throw 'The native launcher compiler did not start.' }
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit(30000)) {
      $process.Kill()
      [void]$process.WaitForExit(5000)
      throw 'Native launcher compilation timed out after 30 seconds.'
    }
    $exitCode = $process.ExitCode
    if ($null -eq $exitCode) { throw 'The native launcher compiler exit code is unavailable.' }
    if (-not [Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($stdoutTask, $stderrTask), 5000)) {
      throw 'Timed out while collecting the native launcher compiler output.'
    }
    if ($exitCode -ne 0) {
      $message = $stdoutTask.Result + $stderrTask.Result
      throw "Native launcher compilation failed (exit ${exitCode}): $message"
    }
  } finally {
    if ($process) {
      try { if ($processStarted -and -not $process.HasExited) { $process.Kill(); [void]$process.WaitForExit(5000) } }
      finally { $process.Dispose() }
    }
  }
  if (-not (Test-AgyNativeShim $stage)) { throw 'The compiled native launcher has no ownership marker.' }
  return [pscustomobject]@{ Path = $stage; SourceHash = $sourceHash; Staged = $true }
}

function Write-AgyHealLog {
  param([string]$Prefix, [string]$Message)
  $line = '[heal] ' + $Message + [Environment]::NewLine
  [IO.File]::AppendAllText((Join-Path $Prefix 'mitm.log'), $line, (New-Object Text.UTF8Encoding($false)))
}

function Test-AgyStableUpdate {
  param([string]$Path, [ref]$ReadyHash)
  $previous = $null
  for ($attempt = 0; $attempt -lt 15; $attempt++) {
    try {
      Assert-AgyUnlinkedPath $Path
      # Content is sampled without excluding updater writes for a long hash.
      # Size/timestamps alone can stay unchanged throughout an in-place update.
      $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
      try {
        if ($stream.Length -lt 10MB -or $stream.ReadByte() -ne 0x4D -or $stream.ReadByte() -ne 0x5A) { return $false }
        $stream.Position = 0
        $hash = [Security.Cryptography.SHA256]::Create()
        try { $digest = [BitConverter]::ToString($hash.ComputeHash($stream)).Replace('-', '') } finally { $hash.Dispose() }
      } finally { $stream.Dispose() }
      if ($digest -ceq $previous) {
        # A short exclusive probe rejects a writer holding its file open. The
        # staged snapshot and displaced-file validation bind this sample later.
        $probe = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
        try { if ($probe.Length -lt 10MB) { return $false } } finally { $probe.Dispose() }
        if ($null -ne $ReadyHash) { $ReadyHash.Value = $digest }
        return $true
      }
      $previous = $digest
    } catch { return $false }
    Start-Sleep -Milliseconds 500
  }
  return $false
}

function New-AgyOriginalSnapshot {
  param($Transaction, [string]$Source, [string]$Destination, [switch]$ValidateUpdate)
  Assert-AgyUnlinkedPath $Source
  Assert-AgyRegularFile $Source
  $stage = Get-AgyUniquePath $Destination
  $Transaction.Temps.Add($stage)
  $input = [IO.File]::Open($Source, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
  try {
    if ($ValidateUpdate) {
      if ($input.Length -lt 10MB -or $input.ReadByte() -ne 0x4D -or $input.ReadByte() -ne 0x5A) {
        throw "The replacement executable is not a complete PE candidate: $Source"
      }
      $input.Position = 0
    }
    $output = [IO.File]::Open($stage, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $input.CopyTo($output); $output.Flush($true) } finally { $output.Dispose() }
  } finally { $input.Dispose() }
  return [pscustomobject]@{ Path = $stage; Hash = (Get-FileHash -LiteralPath $stage -Algorithm SHA256).Hash }
}

function Set-AgyNativeFiles {
  param($Transaction, $State, [string]$Template, $Config, [switch]$ReplaceOriginal)
  Assert-AgyUnlinkedPath $State.shimPath
  if ($State.mode -eq 'inplace') { Assert-AgyUnlinkedPath $State.target }
  $configPath = Join-Path (Split-Path -Parent $State.shimPath) 'agy-launcher.json'
  if ($ReplaceOriginal) {
    $snapshot = New-AgyOriginalSnapshot $Transaction $State.shimPath $State.target -ValidateUpdate:([bool]$State.PSObject.Properties['validateUpdate'])
    if ($State.PSObject.Properties['expectedUpdateHash'] -and $State.expectedUpdateHash -cne $snapshot.Hash) {
      throw "The replacement executable changed after its quiet check; it was left untouched: $($State.shimPath)"
    }
    $Transaction.ExpectedHashes[$State.shimPath] = $snapshot.Hash
    Set-AgyTransactionFile $Transaction $State.target $snapshot.Path
  }
  $sameConfig = $false
  if ([IO.File]::Exists($configPath)) {
    $existing = Read-AgyLauncherConfig $configPath
    $sameConfig = (Test-AgySamePath $existing.target $Config.target) -and $existing.kind -ceq $Config.kind -and
      $existing.port -eq $Config.port -and (Test-AgySamePath $existing.certificate $Config.certificate)
  }
  if (-not $sameConfig) {
    $configStage = New-AgyStagedJson $Transaction $configPath $Config
    Set-AgyTransactionFile $Transaction $configPath $configStage
  }
  $sameBinary = (Test-AgyNativeShim $State.shimPath) -and ((Get-FileHash -LiteralPath $State.shimPath -Algorithm SHA256).Hash -ceq (Get-FileHash -LiteralPath $Template -Algorithm SHA256).Hash)
  if (-not $sameBinary) {
    $shimStage = New-AgyStagedCopy $Transaction $Template $State.shimPath
    Set-AgyTransactionFile $Transaction $State.shimPath $shimStage
  }
}

function Install-AgyWindowsShim {
  param(
    [Parameter(Mandatory = $true)][string]$Prefix,
    [Parameter(Mandatory = $true)][ValidateRange(1, 65535)][int]$Port,
    [Parameter(Mandatory = $true)][string]$Certificate,
    [Parameter(Mandatory = $true)][string]$SourcePath
  )
  $Certificate = Get-AgyFullPath $Certificate
  if (-not [IO.File]::Exists($Certificate)) { throw "Proxy certificate is missing: $Certificate" }
  Invoke-AgyShimLock $Prefix {
    param($root)
    $savedState = Read-AgyShimState $root
    $state = $savedState
    $previousState = $null
    $rediscover = $false
    if ($savedState -and -not [IO.File]::Exists($savedState.target)) {
      $savedShimExists = [IO.File]::Exists($savedState.shimPath)
      $savedShimOwned = Test-AgyNativeShim $savedState.shimPath
      # An in-place update can recreate agy.exe before its saved original exists.
      # Keep that path in the normal stable-PE recovery flow.
      $rediscover = $savedState.mode -eq 'overlay' -or -not $savedShimExists -or $savedShimOwned
    }
    if ($rediscover) {
      [void](Assert-AgyOwnedConfig $savedState)
      if ($savedShimExists -and -not $savedShimOwned) {
        throw "Refusing to replace a foreign saved executable: $($savedState.shimPath)"
      }
      $previousState = $savedState
      $state = Get-AgyCommandTarget $root
      if ($state.mode -eq 'overlay' -and $previousState.mode -eq 'overlay') {
        # The same private wrapper keeps ownership of its existing PATH entries.
        $state.pathAdded = $previousState.pathAdded
        $state | Add-Member -NotePropertyName processPathAdded -NotePropertyValue $previousState.processPathAdded
      }
    }
    $legacy = $null
    if (-not $state) { $legacy = Read-AgyLegacyState $root; $state = $legacy }
    $legacyPath = if ($state -and $state.PSObject.Properties['legacyPath']) { $state.legacyPath } else { $null }
    if ($legacyPath -and -not (Test-AgyLegacyShim $legacyPath)) { throw "The legacy shim is no longer owned: $legacyPath" }
    if (-not $state) { $state = Get-AgyCommandTarget $root }
    $configPath = Join-Path (Split-Path -Parent $state.shimPath) 'agy-launcher.json'
    $reuseShim = $previousState -and (Test-AgySamePath $state.shimPath $previousState.shimPath)
    if ($previousState) {
      if (-not $reuseShim -and [IO.File]::Exists($configPath)) {
        throw "Refusing to replace a foreign launcher configuration: $configPath"
      }
    } elseif ($savedState) { [void](Assert-AgyOwnedConfig $state) }
    elseif ([IO.File]::Exists($configPath)) { throw "Refusing to replace a foreign launcher configuration: $configPath" }
    if ((-not $savedState -or $previousState) -and -not $legacy -and $state.mode -eq 'inplace' -and [IO.File]::Exists($state.target)) {
      throw "Refusing to replace an existing original-binary backup: $($state.target)"
    }
    if ($state.mode -eq 'overlay') {
      if (-not [IO.File]::Exists($state.target)) { throw "The managed agy launcher is missing: $($state.target)" }
      if ([IO.File]::Exists($state.shimPath) -and -not (Test-AgyNativeShim $state.shimPath)) {
        throw "Refusing to replace a foreign overlay executable: $($state.shimPath)"
      }
      $bin = Split-Path -Parent $state.shimPath
      if (-not [IO.Directory]::Exists($bin)) { [void][IO.Directory]::CreateDirectory($bin) }
    }
    $transaction = New-AgyTransaction
    $oldUserPath = Get-AgyUserPath
    $oldProcessPath = $env:Path
    $pathChanged = $false
    try {
      # Complete compilation before making any changes to the original CLI.
      $template = Get-AgyNativeTemplate $root $SourcePath $savedState $transaction
      $replaceOriginal = $false
      if ($state.mode -eq 'inplace') {
        if ([IO.File]::Exists($state.shimPath) -and -not (Test-AgyNativeShim $state.shimPath)) {
          if (($savedState -and -not $previousState) -or $legacy) {
            $readyHash = $null
            if (-not (Test-AgyStableUpdate $state.shimPath -ReadyHash ([ref]$readyHash))) { throw "The replacement agy.exe is incomplete or suspicious; it was left untouched: $($state.shimPath)" }
            $state | Add-Member -NotePropertyName validateUpdate -NotePropertyValue $true -Force
            $state | Add-Member -NotePropertyName expectedUpdateHash -NotePropertyValue $readyHash -Force
          }
          $replaceOriginal = $true
        } elseif (-not [IO.File]::Exists($state.target)) { throw "The original agy executable is missing: $($state.target)" }
        if (Test-AgyNativeShim $state.target) { throw "The saved original is itself a native shim: $($state.target)" }
      }
      if ($template.Staged) { Set-AgyTransactionFile $transaction (Join-Path $root 'agy.exe.tpl') $template.Path }
      $nativeTemplate = Join-Path $root 'agy.exe.tpl'
      $state | Add-Member -NotePropertyName sourceHash -NotePropertyValue $template.SourceHash -Force
      if ($state.mode -eq 'overlay') {
        if (-not (Test-AgyPathContains $oldUserPath $state.pathEntry)) { $state.pathAdded = $true }
        if (-not (Test-AgyPathContains $oldProcessPath $state.pathEntry)) { $state | Add-Member -NotePropertyName processPathAdded -NotePropertyValue $true -Force }
      }
      $config = [ordered]@{ version = 1; target = $state.target; kind = $state.kind; port = $Port; certificate = $Certificate }
      $state | Add-Member -NotePropertyName recoveryConfig -NotePropertyValue $config -Force
      # Recovery metadata must exist before any original executable or user PATH changes.
      $statePath = Join-Path $root 'shim-state.json'
      $stateStage = New-AgyStagedJson $transaction $statePath $state
      Set-AgyTransactionFile $transaction $statePath $stateStage
      if ($state.mode -eq 'overlay') { $pathChanged = $true; Add-AgyOverlayPath $state }
      Set-AgyNativeFiles $transaction $state $nativeTemplate $config -ReplaceOriginal:$replaceOriginal
      if ($previousState -and -not $reuseShim) {
        # Retire the old wrapper only after the new CLI and its config are ready.
        $previousConfig = Assert-AgyOwnedConfig $previousState
        if ([IO.File]::Exists($previousState.shimPath)) {
          if (-not (Test-AgyNativeShim $previousState.shimPath)) {
            throw "The previous executable is no longer owned: $($previousState.shimPath)"
          }
          Remove-AgyTransactionFile $transaction $previousState.shimPath
        }
        Remove-AgyTransactionFile $transaction $previousConfig
        if ($previousState.mode -eq 'overlay') {
          $pathChanged = $true
          if ($previousState.pathAdded) {
            Set-AgyUserPath -Value (Get-AgyPathWithoutEntry (Get-AgyUserPath) $previousState.pathEntry)
          }
          if ($previousState.pathAdded -or $previousState.processPathAdded) {
            $env:Path = Get-AgyPathWithoutEntry $env:Path $previousState.pathEntry
          }
        }
      }
      if ($legacyPath) {
        Remove-AgyTransactionFile $transaction $legacyPath
        Remove-AgyTransactionFile $transaction (Join-Path $root 'shim.path')
        $state.PSObject.Properties.Remove('legacyPath')
        $stateStage = New-AgyStagedJson $transaction $statePath $state
        Set-AgyTransactionFile $transaction $statePath $stateStage
      }
      Complete-AgyTransaction $transaction
    } catch {
      Undo-AgyFailedOperation $transaction $_ $pathChanged $oldUserPath $oldProcessPath
    } finally { Clear-AgyTransactionTemps $transaction }
    if ($pathChanged) { Send-AgyEnvironmentChange }
    return $state
  }
}

function Repair-AgyWindowsShim {
  param([Parameter(Mandatory = $true)][string]$Prefix, [switch]$Watcher)
  Invoke-AgyShimLock $Prefix {
    param($root)
    $state = Read-AgyShimState $root
    if (-not $state) { if ($Watcher) { return 'Blocked' }; return }
    Assert-AgyUnlinkedPath $state.shimPath
    if ($state.mode -eq 'inplace') { Assert-AgyUnlinkedPath $state.target }
    $template = Join-Path $root 'agy.exe.tpl'
    Assert-AgyUnlinkedPath $template
    if (-not (Test-AgyNativeShim $template)) { throw "The native launcher template is missing or invalid: $template" }
    $configPath = Assert-AgyOwnedConfig $state
    $configMissing = -not [IO.File]::Exists($configPath)
    if ($configMissing) {
      # Old installations have no trusted metadata: never guess a port or target.
      if (-not $state.PSObject.Properties['recoveryConfig']) { throw "Launcher configuration is missing; run the installer again: $configPath" }
      $config = $state.recoveryConfig
      if ($config.version -ne 1 -or $config.kind -cne $state.kind -or -not (Test-AgySamePath $config.target $state.target) -or
          ($config.port -isnot [int] -and $config.port -isnot [long]) -or $config.port -lt 1 -or $config.port -gt 65535 -or
          -not [IO.Path]::IsPathRooted($config.certificate)) { throw 'The trusted recovery configuration is invalid; run the installer again.' }
    } else { $config = Read-AgyLauncherConfig $configPath }
    if ((Test-AgyNativeShim $state.shimPath) -and -not $configMissing) {
      if (-not [IO.File]::Exists($state.target)) { if ($Watcher) { return 'Pending' }; throw "The original launcher target is missing: $($state.target)" }
      if ($state.mode -eq 'inplace' -and (Test-AgyNativeShim $state.target)) { throw "The saved original is itself a native shim: $($state.target)" }
      if ($Watcher) { return 'Healthy' }; return
    }
    $replaceOriginal = $false
    if (-not [IO.Directory]::Exists((Split-Path -Parent $state.shimPath))) { if ($Watcher) { return 'Pending' }; return }
    if ($state.mode -eq 'overlay') {
      if ([IO.File]::Exists($state.shimPath) -and -not (Test-AgyNativeShim $state.shimPath)) {
        Write-AgyHealLog $root "foreign overlay executable left untouched: $($state.shimPath)"
        if ($Watcher) { return 'Blocked' }; return
      }
      if (-not [IO.File]::Exists($state.target)) { if ($Watcher) { return 'Pending' }; return }
    } else {
      if ([IO.File]::Exists($state.shimPath) -and -not (Test-AgyNativeShim $state.shimPath)) {
        $readyHash = $null
        if (-not (Test-AgyStableUpdate $state.shimPath -ReadyHash ([ref]$readyHash))) {
          Write-AgyHealLog $root "suspicious or unstable agy.exe (not MZ or <10MB) left untouched: $($state.shimPath)"
          if ($Watcher) { return 'Pending' }; return
        }
        $replaceOriginal = $true
        $state | Add-Member -NotePropertyName validateUpdate -NotePropertyValue $true -Force
        $state | Add-Member -NotePropertyName expectedUpdateHash -NotePropertyValue $readyHash -Force
      } else {
        if (-not [IO.File]::Exists($state.target) -or (Test-AgyNativeShim $state.target)) { throw "The saved original executable is missing or invalid: $($state.target)" }
        if (-not [IO.File]::Exists($state.shimPath)) {
          if ($Watcher) { return 'Pending' }
          # A deletion is not updater completion. Only the manual/five-minute
          # fallback restores a path still absent after a separate quiet period.
          Start-Sleep -Milliseconds 500
          if ([IO.File]::Exists($state.shimPath)) { return }
        }
      }
    }
    $transaction = New-AgyTransaction
    try {
      Set-AgyNativeFiles $transaction $state $template $config -ReplaceOriginal:$replaceOriginal
      Complete-AgyTransaction $transaction
    } catch { $failure = $_; Undo-AgyTransaction $transaction; throw $failure }
    finally { Clear-AgyTransactionTemps $transaction }
    Write-AgyHealLog $root "restored native launcher: $($state.shimPath)"
    if ($Watcher) { return 'Repaired' }
  }
}

function Get-AgyWatcherExecutable {
  param([string]$Prefix, [string]$SourcePath)
  Assert-AgyUnlinkedPath $Prefix
  Assert-AgyUnlinkedPath $SourcePath
  $destination = Join-Path $Prefix 'agy-watcher.exe'
  Assert-AgyUnlinkedPath $destination
  if ([IO.File]::Exists($destination) -and [Diagnostics.FileVersionInfo]::GetVersionInfo($destination).FileDescription -cne 'agy-region-fixer-watcher-v1') {
    throw "Refusing to replace a foreign watcher executable: $destination"
  }
  $compiler = $null
  foreach ($framework in @('Framework64', 'Framework')) {
    $candidate = Join-Path $env:WINDIR "Microsoft.NET\$framework\v4.0.30319\csc.exe"
    if ([IO.File]::Exists($candidate)) { $compiler = $candidate; break }
  }
  if (-not $compiler) { throw 'The Windows .NET Framework C# compiler was not found.' }
  $stage = Get-AgyUniquePath $destination
  $start = New-Object Diagnostics.ProcessStartInfo
  $start.FileName = $compiler
  $start.Arguments = '/nologo /target:winexe /optimize+ /platform:anycpu /out:"' + $stage + '" "' + $SourcePath + '"'
  $start.UseShellExecute = $false
  $start.CreateNoWindow = $true
  $start.RedirectStandardOutput = $true
  $start.RedirectStandardError = $true
  $process = New-Object Diagnostics.Process
  $process.StartInfo = $start
  $started = $false
  try {
    $started = $process.Start()
    if (-not $started) { throw 'The watcher compiler did not start.' }
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit(30000)) { throw 'Watcher compilation timed out after 30 seconds.' }
    if (-not [Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($stdout, $stderr), 5000)) { throw 'Timed out collecting watcher compiler output.' }
    if ($process.ExitCode -ne 0) { throw "Watcher compilation failed: $($stdout.Result)$($stderr.Result)" }
    if ([Diagnostics.FileVersionInfo]::GetVersionInfo($stage).FileDescription -cne 'agy-region-fixer-watcher-v1') { throw 'The compiled watcher has no ownership marker.' }
    if ([IO.File]::Exists($destination)) { [IO.File]::Replace($stage, $destination, [NullString]::Value) }
    else { [IO.File]::Move($stage, $destination) }
  } finally {
    try { if ($started -and -not $process.HasExited) { $process.Kill(); [void]$process.WaitForExit(5000) } }
    finally { $process.Dispose(); if ([IO.File]::Exists($stage)) { [IO.File]::Delete($stage) } }
  }
  return $destination
}

function Stop-AgyWindowsWatcher {
  param([string]$Prefix)
  Assert-AgyUnlinkedPath $Prefix
  $executable = Join-Path $Prefix 'agy-watcher.exe'
  $disabled = Join-Path $Prefix 'watcher.disabled'
  Assert-AgyUnlinkedPath $disabled
  [IO.File]::WriteAllText($disabled, 'Disabled by installer or uninstaller.', (New-Object Text.UTF8Encoding($false)))
  # Disable future starts before signaling. Never stop a running repair through
  # Task Scheduler: it must release the shim transaction lock itself.
  $task = Get-ScheduledTask -TaskName 'agy-region-fixer-watch' -ErrorAction SilentlyContinue
  if ($task) {
    if (@($task.Actions).Count -ne 1 -or -not (Test-AgySamePath $task.Actions[0].Execute $executable)) { throw 'The watcher task belongs to another executable; it was left untouched.' }
    Disable-ScheduledTask -InputObject $task -ErrorAction Stop | Out-Null
  }
  $fallback = Get-ScheduledTask -TaskName 'agy-region-fixer-heal' -ErrorAction SilentlyContinue
  if ($fallback) {
    $expected = Join-Path $Prefix 'heal.ps1'
    if ($fallback.Actions[0].Arguments -notmatch ('(?i)(?:"|\s)' + [regex]::Escape($expected) + '(?:"|\s|$)')) { throw 'The heal task belongs to another installation; it was left untouched.' }
    Disable-ScheduledTask -InputObject $fallback -ErrorAction Stop | Out-Null
  }
  if (-not [IO.File]::Exists($executable)) { return }
  Assert-AgyUnlinkedPath $executable
  if ([Diagnostics.FileVersionInfo]::GetVersionInfo($executable).FileDescription -cne 'agy-region-fixer-watcher-v1') { throw "Refusing to signal a foreign watcher: $executable" }
  $start = New-Object Diagnostics.ProcessStartInfo
  $start.FileName = $executable
  $start.Arguments = '--stop "' + $Prefix + '"'
  $start.UseShellExecute = $false
  $start.CreateNoWindow = $true
  $process = [Diagnostics.Process]::Start($start)
  try {
    if (-not $process.WaitForExit(50000)) { throw 'Watcher stop control timed out; installation files were preserved.' }
    if ($process.ExitCode -ne 0) { throw 'The watcher has not stopped; installation files were preserved.' }
  } finally {
    # This is the exact control child, never the watcher or a repair process.
    if (-not $process.HasExited) { $process.Kill(); [void]$process.WaitForExit(5000) }
    $process.Dispose()
  }
}

function Start-AgyWindowsWatcher {
  param([string]$Prefix, $State)
  $executable = Join-Path $Prefix 'agy-watcher.exe'
  Assert-AgyUnlinkedPath $executable
  if ([Diagnostics.FileVersionInfo]::GetVersionInfo($executable).FileDescription -cne 'agy-region-fixer-watcher-v1') { throw "The watcher executable is not owned: $executable" }
  $arguments = '--run "' + $Prefix + '" "' + $State.shimPath + '" "' + $State.target + '"'
  $action = New-ScheduledTaskAction -Execute $executable -Argument $arguments
  $user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
  $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
  $trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
  $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartInterval (New-TimeSpan -Minutes 1) -RestartCount 3 -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
  Register-ScheduledTask -TaskName 'agy-region-fixer-watch' -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force -ErrorAction Stop | Out-Null
  $disabled = Join-Path $Prefix 'watcher.disabled'
  Assert-AgyUnlinkedPath $disabled
  if ([IO.File]::Exists($disabled)) { [IO.File]::Delete($disabled) }
  Start-ScheduledTask -TaskName 'agy-region-fixer-watch' -ErrorAction Stop
  # Status is a named-event readiness check; it does not poll the filesystem.
  $deadline = [Diagnostics.Stopwatch]::StartNew()
  do {
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $executable
    $start.Arguments = '--status "' + $Prefix + '"'
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $probe = [Diagnostics.Process]::Start($start)
    try {
      if (-not $probe.WaitForExit(2000)) { throw 'Watcher readiness control timed out.' }
      if ($probe.ExitCode -eq 0) { return }
    } finally {
      if (-not $probe.HasExited) { $probe.Kill(); [void]$probe.WaitForExit(1000) }
      $probe.Dispose()
    }
    Start-Sleep -Milliseconds 100
  } while ($deadline.ElapsedMilliseconds -lt 15000)
  throw "The watcher did not become ready; check $(Join-Path $Prefix 'watcher.log')."
}

function Remove-AgyWindowsShim {
  param([Parameter(Mandatory = $true)][string]$Prefix)
  Invoke-AgyShimLock $Prefix {
    param($root)
    $state = Read-AgyShimState $root
    if (-not $state) {
      $legacy = Read-AgyLegacyState $root
      if (-not $legacy) { return }
      $state = $legacy
    }
    $configPath = Assert-AgyOwnedConfig $state
    $transaction = New-AgyTransaction
    $oldUserPath = Get-AgyUserPath
    $oldProcessPath = $env:Path
    $pathChanged = $false
    try {
      $ownedShim = Test-AgyNativeShim $state.shimPath
      if ($state.mode -eq 'overlay' -and [IO.File]::Exists($state.shimPath) -and -not $ownedShim) {
        throw "A foreign executable is present in the private overlay directory; uninstall was stopped to preserve it: $($state.shimPath)"
      }
      if ($state.mode -eq 'inplace') {
        if ($ownedShim -or -not [IO.File]::Exists($state.shimPath)) {
          if (-not [IO.File]::Exists($state.target) -or (Test-AgyNativeShim $state.target)) { throw "Cannot restore the original agy executable: $($state.target)" }
          $restore = New-AgyStagedCopy $transaction $state.target $state.shimPath
          Set-AgyTransactionFile $transaction $state.shimPath $restore
          Remove-AgyTransactionFile $transaction $state.target
        }
        # A foreign replacement or a newly arrived update remains in place.
        # Its existing agy.real.exe is also kept, outside the private prefix.
      } elseif ($ownedShim) { Remove-AgyTransactionFile $transaction $state.shimPath }
      Remove-AgyTransactionFile $transaction $configPath
      if ($state.PSObject.Properties['legacyPath'] -and $state.legacyPath) { Remove-AgyTransactionFile $transaction $state.legacyPath }
      if ($state.mode -eq 'overlay') {
        $entry = Join-Path $root 'bin'
        $pathChanged = $true
        if ($state.pathAdded) { Set-AgyUserPath -Value (Get-AgyPathWithoutEntry $oldUserPath $entry) }
        if ($state.pathAdded -or $state.processPathAdded) { $env:Path = Get-AgyPathWithoutEntry $oldProcessPath $entry }
      }
      Remove-AgyTransactionFile $transaction (Join-Path $root 'shim-state.json')
      Remove-AgyTransactionFile $transaction (Join-Path $root 'shim.path')
      Complete-AgyTransaction $transaction
    } catch {
      Undo-AgyFailedOperation $transaction $_ $pathChanged $oldUserPath $oldProcessPath
    } finally { Clear-AgyTransactionTemps $transaction }
    if ($pathChanged) { Send-AgyEnvironmentChange }
  }
}
'@
$windowsLauncherSource = @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Reflection;
using System.Text;
using System.Web.Script.Serialization;

[assembly: AssemblyDescription("agy-region-fixer-native-shim-v1")]
[assembly: AssemblyTitle("agy-region-fixer-native-shim-v1")]
[assembly: AssemblyVersion("1.0.0.0")]

internal static class Launcher
{
    private const string Marker = "agy-region-fixer-native-shim-v1";
    private const int ConfigurationLimit = 65536;
    private const int WindowsCommandLineLimit = 32766;
    private const int CmdCommandLineLimit = 8190;
    private const int ProbeTimeoutMilliseconds = 1000;
    private const int CannotExecute = 126;
    private const int CommandNotFound = 127;

    private sealed class Configuration
    {
        internal string Target;
        internal string Kind;
        internal string Certificate;
        internal int Port;
    }

    private sealed class LauncherException : Exception
    {
        internal readonly int ExitCode;

        internal LauncherException(string message, int exitCode)
            : base(message)
        {
            ExitCode = exitCode;
        }
    }

    private static int Main(string[] arguments)
    {
        // The child shares this console and receives the same Ctrl+C/Ctrl+Break.
        // Keep waiting for it rather than leaving an interactive child behind.
        ConsoleCancelEventHandler cancelHandler = delegate(object sender, ConsoleCancelEventArgs e)
        {
            e.Cancel = true;
        };
        Console.CancelKeyPress += cancelHandler;
        try
        {
            string ownPath = Path.GetFullPath(Assembly.GetExecutingAssembly().Location);
            Configuration configuration = ReadConfiguration(ownPath);
            ProcessStartInfo start = CreateStartInfo(configuration, arguments);
            if (IsProxyAlive(configuration.Port))
            {
                start.EnvironmentVariables["SSL_CERT_FILE"] = configuration.Certificate;
                start.EnvironmentVariables["HTTPS_PROXY"] =
                    "http://127.0.0.1:" + configuration.Port.ToString(CultureInfo.InvariantCulture);
            }

            using (Process child = Process.Start(start))
            {
                if (child == null)
                    throw new LauncherException("could not start the configured target", CannotExecute);
                child.WaitForExit();
                return child.ExitCode;
            }
        }
        catch (LauncherException e)
        {
            Console.Error.WriteLine("agy: " + e.Message);
            return e.ExitCode;
        }
        catch (Win32Exception e)
        {
            Console.Error.WriteLine("agy: could not start the configured target (Windows error " +
                e.NativeErrorCode.ToString(CultureInfo.InvariantCulture) + ")");
            return e.NativeErrorCode == 2 || e.NativeErrorCode == 3 ? CommandNotFound : CannotExecute;
        }
        catch (Exception e)
        {
            if (!(e is IOException) && !(e is UnauthorizedAccessException) &&
                !(e is ArgumentException) && !(e is InvalidOperationException) &&
                !(e is NotSupportedException) && !(e is System.Security.SecurityException))
                throw;
            Console.Error.WriteLine("agy: could not read configuration or launch the configured target");
            return CannotExecute;
        }
        finally
        {
            Console.CancelKeyPress -= cancelHandler;
        }
    }

    private static Configuration ReadConfiguration(string ownPath)
    {
        string configPath = Path.Combine(Path.GetDirectoryName(ownPath), "agy-launcher.json");
        if (!File.Exists(configPath))
            throw new LauncherException("agy-launcher.json is missing; reinstall the launcher", CannotExecute);

        string text;
        using (FileStream stream = File.OpenRead(configPath))
        {
            byte[] bytes = new byte[ConfigurationLimit + 1];
            int count = 0;
            int read;
            while (count < bytes.Length &&
                (read = stream.Read(bytes, count, bytes.Length - count)) != 0)
                count += read;
            if (count > ConfigurationLimit)
                throw InvalidConfiguration();
            int offset = count >= 3 && bytes[0] == 0xef && bytes[1] == 0xbb && bytes[2] == 0xbf ? 3 : 0;
            try
            {
                text = new UTF8Encoding(false, true).GetString(bytes, offset, count - offset);
            }
            catch (DecoderFallbackException)
            {
                throw InvalidConfiguration();
            }
        }

        Dictionary<string, object> values;
        try
        {
            JavaScriptSerializer serializer = new JavaScriptSerializer();
            serializer.MaxJsonLength = ConfigurationLimit;
            serializer.RecursionLimit = 4;
            values = serializer.DeserializeObject(text) as Dictionary<string, object>;
        }
        catch (ArgumentException)
        {
            throw InvalidConfiguration();
        }
        catch (InvalidOperationException)
        {
            throw InvalidConfiguration();
        }
        catch (FormatException)
        {
            throw InvalidConfiguration();
        }
        catch (OverflowException)
        {
            throw InvalidConfiguration();
        }

        object version;
        object port;
        object target;
        object kind;
        object certificate;
        if (values == null || values.Count != 5 ||
            !values.TryGetValue("version", out version) || !(version is int) || (int)version != 1 ||
            !values.TryGetValue("port", out port) || !(port is int) || (int)port < 1 || (int)port > 65535 ||
            !values.TryGetValue("target", out target) || !(target is string) ||
            !values.TryGetValue("kind", out kind) || !(kind is string) ||
            !values.TryGetValue("certificate", out certificate) || !(certificate is string))
            throw InvalidConfiguration();

        string targetPath = AbsolutePath((string)target);
        string certificatePath = AbsolutePath((string)certificate);
        string targetKind = (string)kind;
        if (targetKind != "exe" && targetKind != "cmd" && targetKind != "ps1")
            throw InvalidConfiguration();
        if (!String.Equals(Path.GetExtension(targetPath), "." + targetKind, StringComparison.OrdinalIgnoreCase))
            throw InvalidConfiguration();
        if (String.Equals(targetPath, ownPath, StringComparison.OrdinalIgnoreCase))
            throw new LauncherException("the configured target points to the launcher itself", CannotExecute);
        if (!File.Exists(targetPath))
            throw new LauncherException("the configured target is missing; reinstall the CLI or launcher", CommandNotFound);
        if (targetKind == "exe" && IsNativeLauncher(targetPath))
            throw new LauncherException("the configured target is another region-fixer launcher", CannotExecute);

        return new Configuration
        {
            Target = targetPath,
            Kind = targetKind,
            Certificate = certificatePath,
            Port = (int)port
        };
    }

    private static LauncherException InvalidConfiguration()
    {
        return new LauncherException("agy-launcher.json is invalid; reinstall the launcher", CannotExecute);
    }

    private static string AbsolutePath(string value)
    {
        bool drivePath = value.Length >= 3 &&
            ((value[0] >= 'A' && value[0] <= 'Z') || (value[0] >= 'a' && value[0] <= 'z')) &&
            value[1] == ':' && (value[2] == '\\' || value[2] == '/');
        bool uncPath = value.StartsWith(@"\\", StringComparison.Ordinal) &&
            !value.StartsWith(@"\\.\", StringComparison.Ordinal) &&
            !value.StartsWith(@"\\?\", StringComparison.Ordinal);
        if ((!drivePath && !uncPath) || value.IndexOf('\0') >= 0)
            throw InvalidConfiguration();
        try
        {
            string fullPath = Path.GetFullPath(value);
            if (uncPath)
            {
                string[] components = fullPath.Substring(2).Split('\\');
                if (components.Length < 3 || components[0].Length == 0 || components[1].Length == 0)
                    throw InvalidConfiguration();
            }
            return fullPath;
        }
        catch (ArgumentException) { throw InvalidConfiguration(); }
        catch (NotSupportedException) { throw InvalidConfiguration(); }
        catch (PathTooLongException) { throw InvalidConfiguration(); }
    }

    private static bool IsNativeLauncher(string path)
    {
        try
        {
            return String.Equals(FileVersionInfo.GetVersionInfo(path).FileDescription,
                Marker, StringComparison.Ordinal);
        }
        catch (Win32Exception)
        {
            // App execution aliases may not expose version resources.
            return false;
        }
    }

    private static ProcessStartInfo CreateStartInfo(Configuration configuration, string[] arguments)
    {
        ProcessStartInfo start = new ProcessStartInfo();
        start.UseShellExecute = false;
        start.CreateNoWindow = false;
        start.WorkingDirectory = Environment.CurrentDirectory;
        if (configuration.Kind == "exe")
        {
            start.FileName = configuration.Target;
            start.Arguments = QuoteArguments(arguments);
        }
        else if (configuration.Kind == "cmd")
        {
            start.FileName = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "cmd.exe");
            StringBuilder command = new StringBuilder();
            command.Append('"');
            command.Append(EscapeCmd(configuration.Target));
            foreach (string argument in arguments)
            {
                command.Append(' ');
                command.Append(EscapeCmd(EscapeCmd(QuoteArgument(argument))));
            }
            command.Append('"');
            if (command.Length > CmdCommandLineLimit)
                throw new LauncherException("arguments exceed the cmd.exe command-line limit", CannotExecute);
            start.Arguments = "/d /v:off /s /c " + command.ToString();
        }
        else
        {
            start.FileName = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),
                @"WindowsPowerShell\v1.0\powershell.exe");
            string targetLiteral = Convert.ToBase64String(Encoding.Unicode.GetBytes(configuration.Target));
            string json = new JavaScriptSerializer().Serialize(arguments);
            string argumentsLiteral = Convert.ToBase64String(Encoding.Unicode.GetBytes(json));
            // Windows PowerShell emits JSON arrays as one pipeline object. Cast
            // directly so an array subexpression cannot nest it before splatting.
            string script = "$ProgressPreference='SilentlyContinue';$target=[Text.Encoding]::Unicode.GetString([Convert]::FromBase64String('" +
                targetLiteral + "'));$arguments=[string[]](ConvertFrom-Json -InputObject " +
                "([Text.Encoding]::Unicode.GetString([Convert]::FromBase64String('" + argumentsLiteral +
                "'))));if($null -eq $arguments){$arguments=[string[]]@()};& $target @arguments;$succeeded=$?;" +
                "if($null -ne $LASTEXITCODE){exit $LASTEXITCODE};if($succeeded){exit 0}else{exit 1}";
            start.Arguments = "-NoLogo -NoProfile -ExecutionPolicy Bypass -InputFormat Text -OutputFormat Text -EncodedCommand " +
                Convert.ToBase64String(Encoding.Unicode.GetBytes(script));
        }

        if ((long)start.FileName.Length + start.Arguments.Length + 3 > WindowsCommandLineLimit)
            throw new LauncherException("arguments exceed the Windows command-line limit", CannotExecute);
        return start;
    }

    private static string QuoteArguments(string[] arguments)
    {
        StringBuilder result = new StringBuilder();
        foreach (string argument in arguments)
        {
            if (result.Length != 0)
                result.Append(' ');
            result.Append(QuoteArgument(argument));
        }
        return result.ToString();
    }

    private static string QuoteArgument(string argument)
    {
        StringBuilder result = new StringBuilder();
        result.Append('"');
        int backslashes = 0;
        foreach (char character in argument)
        {
            if (character == '\\')
            {
                backslashes++;
                continue;
            }
            if (character == '"')
                result.Append('\\', backslashes * 2 + 1);
            else
                result.Append('\\', backslashes);
            result.Append(character);
            backslashes = 0;
        }
        result.Append('\\', backslashes * 2);
        result.Append('"');
        return result.ToString();
    }

    private static string EscapeCmd(string value)
    {
        // cmd shims parse forwarded arguments twice, so callers escape arguments
        // twice after CRT quoting, and escape the command path once.
        // https://github.com/moxystudio/node-cross-spawn/blob/master/lib/util/escape.js
        const string metacharacters = "()[]%!^\"`<>&|;, *?";
        StringBuilder result = new StringBuilder();
        foreach (char character in value)
        {
            if (metacharacters.IndexOf(character) >= 0)
                result.Append('^');
            result.Append(character);
        }
        return result.ToString();
    }

    private static bool IsProxyAlive(int port)
    {
        using (TcpClient client = new TcpClient(AddressFamily.InterNetwork))
        {
            try
            {
                IAsyncResult pending = client.BeginConnect(IPAddress.Loopback, port, null, null);
                using (System.Threading.WaitHandle completed = pending.AsyncWaitHandle)
                {
                    if (!completed.WaitOne(ProbeTimeoutMilliseconds))
                        return false;
                    client.EndConnect(pending);
                    return true;
                }
            }
            catch (SocketException) { return false; }
        }
    }
}
'@

# --- shim ------------------------------------------------------------------
$windowsWatcherSource = @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.IO.MemoryMappedFiles;
using System.Reflection;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using System.Threading;

[assembly: AssemblyDescription("agy-region-fixer-watcher-v1")]
[assembly: AssemblyTitle("agy-region-fixer-watcher-v1")]
[assembly: AssemblyVersion("1.0.0.0")]

internal static class AgyWatcher
{
    private const int QuietMilliseconds = 500;
    private const int ChildTimeoutMilliseconds = 20000;
    private const int BurstMilliseconds = 45000;
    private const int MaximumAttempts = 6;
    private const int MaximumWatches = 64;
    private const int OutputLimit = 4096;
    private static readonly AutoResetEvent Changed = new AutoResetEvent(false);
    private static int generation;
    private static string prefix;
    private static readonly List<FileSystemWatcher> subscriptions = new List<FileSystemWatcher>();
    private static readonly HashSet<string> logicalPaths = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
    private static readonly Dictionary<string, bool> desired = new Dictionary<string, bool>(StringComparer.OrdinalIgnoreCase);

    // Callbacks never touch disk or run PowerShell. The sole worker reconciles
    // the latest state, including changes delivered while a repair is running.
    private static void Dirty(object sender, FileSystemEventArgs args)
    {
        Interlocked.Increment(ref generation);
        Changed.Set();
    }
    private static void Overflow(object sender, ErrorEventArgs args)
    {
        Interlocked.Increment(ref generation);
        Changed.Set();
    }
    private static string FullPath(string path)
    {
        if (!Path.IsPathRooted(path)) throw new IOException("An absolute path is required: " + path);
        string full = Path.GetFullPath(path);
        return full.Length == Path.GetPathRoot(full).Length ? full : full.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
    }
    private static void AssertUnlinked(string path)
    {
        string current = FullPath(path);
        while (!String.IsNullOrEmpty(current))
        {
            if ((File.Exists(current) || Directory.Exists(current)) &&
                (File.GetAttributes(current) & FileAttributes.ReparsePoint) != 0)
                throw new IOException("Refusing a linked watcher path: " + current);
            string parent = Path.GetDirectoryName(current);
            if (String.Equals(parent, current, StringComparison.OrdinalIgnoreCase)) break;
            current = parent;
        }
    }
    private static string Identity()
    {
        string user = WindowsIdentity.GetCurrent().User.Value;
        using (SHA256 hash = SHA256.Create())
            return "Local\\AgyRegionWatcher-" + BitConverter.ToString(hash.ComputeHash(Encoding.UTF8.GetBytes(user + "\n" + prefix.ToUpperInvariant()))).Replace("-", "");
    }
    private static void AddLogicalPath(string path)
    {
        string current = FullPath(path);
        while (!String.IsNullOrEmpty(current))
        {
            if (logicalPaths.Count >= MaximumWatches && !logicalPaths.Contains(current))
                throw new IOException("Watcher path depth exceeds its bounded logical-path limit.");
            logicalPaths.Add(current);
            string parent = Path.GetDirectoryName(current);
            if (String.IsNullOrEmpty(parent) || String.Equals(parent, current, StringComparison.OrdinalIgnoreCase)) break;
            current = parent;
        }
    }
    private static bool SamePath(string left, string right)
    {
        return String.Equals(FullPath(left), FullPath(right), StringComparison.OrdinalIgnoreCase);
    }
    private static bool Beneath(string path, string ancestor)
    {
        return FullPath(path).StartsWith(FullPath(ancestor).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar) + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase);
    }
    private static bool BroadAnchor(string path)
    {
        string full = FullPath(path);
        string profile = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        if (SamePath(full, Path.GetPathRoot(full)) || SamePath(full, profile) || Beneath(profile, full)) return true;
        foreach (var folder in new[] { Environment.SpecialFolder.Windows, Environment.SpecialFolder.System,
            Environment.SpecialFolder.ProgramFiles, Environment.SpecialFolder.ProgramFilesX86,
            Environment.SpecialFolder.CommonProgramFiles, Environment.SpecialFolder.CommonProgramFilesX86,
            Environment.SpecialFolder.CommonApplicationData, Environment.SpecialFolder.ApplicationData,
            Environment.SpecialFolder.LocalApplicationData })
        {
            string shared = Environment.GetFolderPath(folder);
            if (!String.IsNullOrEmpty(shared) && SamePath(full, shared)) return true;
        }
        string local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        return !String.IsNullOrEmpty(local) && SamePath(full, Path.Combine(local, "Programs"));
    }
    private static void AddWatchAndParents(string directory, bool recursive)
    {
        string current = FullPath(directory);
        while (!String.IsNullOrEmpty(current))
        {
            bool previous;
            desired.TryGetValue(current, out previous);
            desired[current] = previous || recursive;
            string parent = Path.GetDirectoryName(current);
            if (String.IsNullOrEmpty(parent) || String.Equals(parent, current, StringComparison.OrdinalIgnoreCase)) break;
            current = parent;
            recursive = false;
        }
    }
    private static void ConfigureSubscriptions(string shim)
    {
        string directory = Path.GetDirectoryName(FullPath(shim));
        string anchor = Path.GetDirectoryName(directory);
        // A child-directory watch pins its ancestors against rename on Windows,
        // even with FILE_SHARE_DELETE. Keep the application subtree behind one
        // recursive handle on its anchor, never handles inside that subtree.
        bool recursive = !String.IsNullOrEmpty(anchor) && !BroadAnchor(anchor);
        if (!recursive) anchor = directory;
        AddWatchAndParents(anchor, recursive);
        // Metadata needs a direct owned-prefix watch, never a recursive profile
        // watch. Managed launchers stay external and need no directory handles.
        AddWatchAndParents(prefix, false);
        var covered = new List<string>();
        foreach (var pair in desired)
            foreach (var candidate in desired)
                if (candidate.Value && Beneath(pair.Key, candidate.Key)) { covered.Add(pair.Key); break; }
        foreach (string path in covered) desired.Remove(path);
        if (desired.Count > MaximumWatches) throw new IOException("Watcher subscription count exceeds its bounded limit.");
    }
    private static void RefreshSubscriptions()
    {
        // Install new subscriptions before retiring old ones. Watching each
        // ancestor's next component notices directory replacement at logical paths.
        var next = new List<FileSystemWatcher>();
        try
        {
            foreach (var pair in desired)
            {
                if (!Directory.Exists(pair.Key)) continue;
                // Subscriptions only observe; heal validates every writable path.
                var names = logicalPaths;
                var watcher = new FileSystemWatcher(pair.Key);
                next.Add(watcher);
                watcher.IncludeSubdirectories = pair.Value;
                watcher.NotifyFilter = NotifyFilters.FileName | NotifyFilters.DirectoryName | NotifyFilters.LastWrite | NotifyFilters.Size;
                watcher.InternalBufferSize = 8192;
                FileSystemEventHandler onChange = delegate(object sender, FileSystemEventArgs args) {
                    if (names.Contains(args.FullPath)) Dirty(sender, args);
                };
                watcher.Changed += onChange;
                watcher.Created += onChange;
                watcher.Deleted += onChange;
                watcher.Renamed += delegate(object sender, RenamedEventArgs args) {
                    if (names.Contains(args.FullPath) || names.Contains(args.OldFullPath)) Dirty(sender, args);
                };
                watcher.Error += Overflow;
                watcher.EnableRaisingEvents = true;
            }
        }
        catch
        {
            foreach (var watcher in next) watcher.Dispose();
            throw;
        }
        foreach (var watcher in subscriptions) watcher.Dispose();
        subscriptions.Clear();
        subscriptions.AddRange(next);
    }
    private static string Quote(string value)
    {
        // Windows CRT quoting, also used when the profile contains spaces.
        var result = new StringBuilder("\"");
        int slashes = 0;
        foreach (char character in value)
        {
            if (character == '\\') { slashes++; continue; }
            result.Append('\\', character == '"' ? slashes * 2 + 1 : slashes);
            result.Append(character);
            slashes = 0;
        }
        result.Append('\\', slashes * 2);
        return result.Append('"').ToString();
    }
    private sealed class BoundedOutput
    {
        private readonly StringBuilder tail = new StringBuilder();
        internal void Drain(StreamReader reader)
        {
            try
            {
                var buffer = new char[1024];
                int count;
                while ((count = reader.Read(buffer, 0, buffer.Length)) != 0)
                {
                    lock (tail)
                    {
                        tail.Append(buffer, 0, count);
                        if (tail.Length > OutputLimit) tail.Remove(0, tail.Length - OutputLimit);
                    }
                }
            }
            catch (IOException) { }
            catch (ObjectDisposedException) { }
        }
        public override string ToString() { lock (tail) return tail.ToString(); }
    }
    private static void Log(string message)
    {
        string path = Path.Combine(prefix, "watcher.log");
        AssertUnlinked(path);
        if (File.Exists(path) && new FileInfo(path).Length > 131072) File.Delete(path);
        File.AppendAllText(path, DateTime.UtcNow.ToString("o") + " " + message + Environment.NewLine, new UTF8Encoding(false));
    }
    private static int Reconcile(int remainingMilliseconds)
    {
        AssertUnlinked(prefix);
        string heal = Path.Combine(prefix, "heal.ps1");
        AssertUnlinked(heal);
        if (!File.Exists(heal)) throw new IOException("The owned heal script is missing: " + heal);
        var start = new ProcessStartInfo();
        start.FileName = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "WindowsPowerShell\\v1.0\\powershell.exe");
        start.Arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File " + Quote(heal) + " -Watcher";
        start.UseShellExecute = false;
        start.CreateNoWindow = true;
        start.RedirectStandardOutput = true;
        start.RedirectStandardError = true;
        using (var process = new Process())
        {
            process.StartInfo = start;
            if (!process.Start()) throw new IOException("The owned heal process did not start.");
            var output = new BoundedOutput();
            var stdout = new Thread(delegate() { output.Drain(process.StandardOutput); });
            var stderr = new Thread(delegate() { output.Drain(process.StandardError); });
            stdout.IsBackground = true;
            stderr.IsBackground = true;
            stdout.Start();
            stderr.Start();
            try
            {
                if (!process.WaitForExit(Math.Max(1, Math.Min(ChildTimeoutMilliseconds, remainingMilliseconds))))
                {
                    process.Kill();
                    if (!process.WaitForExit(5000)) throw new IOException("The timed-out heal process could not be stopped.");
                    throw new IOException("The owned heal process timed out.");
                }
                if (!stdout.Join(2000) || !stderr.Join(2000)) throw new IOException("Timed out collecting bounded heal output.");
                int result = process.ExitCode;
                if (result != 0 && result != 10 && result != 20 && result != 21)
                    throw new IOException("Heal failed (" + result + "): " + output.ToString());
                return result;
            }
            finally
            {
                if (!process.HasExited) { process.Kill(); process.WaitForExit(5000); }
                process.StandardOutput.Close();
                process.StandardError.Close();
                stdout.Join(2000);
                stderr.Join(2000);
            }
        }
    }
    private static bool WaitForQuiet(EventWaitHandle stop, Stopwatch burst)
    {
        while (burst.ElapsedMilliseconds < BurstMilliseconds)
        {
            int before = Volatile.Read(ref generation);
            int signaled = WaitHandle.WaitAny(new WaitHandle[] { stop, Changed }, QuietMilliseconds);
            if (signaled == 0) return false;
            if (signaled == WaitHandle.WaitTimeout && before == Volatile.Read(ref generation)) return true;
        }
        return true;
    }
    private static int Run(string[] args, string identity)
    {
        if (args.Length != 4) throw new ArgumentException("Usage: agy-watcher.exe --run PREFIX SHIM TARGET");
        string disabled = Path.Combine(prefix, "watcher.disabled");
        AssertUnlinked(disabled);
        if (File.Exists(disabled)) return 0;
        AssertUnlinked(args[2]);
        string shimDirectory = Path.GetDirectoryName(FullPath(args[2]));
        foreach (string path in new[] { args[2], Path.Combine(shimDirectory, "agy-launcher.json"), Path.Combine(prefix, "shim-state.json") })
            AddLogicalPath(path);
        if (SamePath(shimDirectory, Path.GetDirectoryName(FullPath(args[3])))) AddLogicalPath(args[3]);
        ConfigureSubscriptions(args[2]);
        using (var mutex = new Mutex(false, identity + "-owner"))
        {
            bool owned;
            try { owned = mutex.WaitOne(0); } catch (AbandonedMutexException) { owned = true; }
            if (!owned) return 0;
            try
            {
                using (var owner = MemoryMappedFile.CreateOrOpen(identity + "-process", 16))
                using (var record = owner.CreateViewAccessor())
                using (var current = Process.GetCurrentProcess())
                using (var stop = new EventWaitHandle(false, EventResetMode.ManualReset, identity + "-stop"))
                using (var ready = new EventWaitHandle(false, EventResetMode.ManualReset, identity + "-ready"))
                {
                    record.Write(0, 0);
                    record.Write(8, current.StartTime.ToUniversalTime().Ticks);
                    record.Write(0, current.Id);
                    ready.Reset();
                    if (File.Exists(disabled) || stop.WaitOne(0)) return 0;
                    RefreshSubscriptions(); // Subscribe before the initial reconciliation.
                    Changed.Set();
                    while (WaitHandle.WaitAny(new WaitHandle[] { stop, Changed }) != 0)
                    {
                        var burst = Stopwatch.StartNew();
                        int result = 20;
                        for (int attempt = 0; attempt < MaximumAttempts && burst.ElapsedMilliseconds < BurstMilliseconds; attempt++)
                        {
                            if (!WaitForQuiet(stop, burst)) return 0;
                            if (burst.ElapsedMilliseconds >= BurstMilliseconds) { result = 20; break; }
                            RefreshSubscriptions();
                            int observed = Volatile.Read(ref generation);
                            result = Reconcile(BurstMilliseconds - (int)burst.ElapsedMilliseconds);
                            ready.Set();
                            if (stop.WaitOne(0)) return 0;
                            if (result == 21) break;
                            if (result != 20 && observed == Volatile.Read(ref generation)) break;
                            if (stop.WaitOne(1000)) return 0;
                        }
                        if (result == 20 || result == 21) Log(result == 20 ? "Pending; awaiting a filesystem event or the five-minute fallback." : "Blocked; awaiting a filesystem event or manual recovery.");
                        // Exhausted work does not create an idle polling timer.
                        // A newly delivered event remains signaled for the next burst.
                    }
                    return 0;
                }
            }
            finally
            {
                foreach (var watcher in subscriptions) watcher.Dispose();
                subscriptions.Clear();
                mutex.ReleaseMutex();
            }
        }
    }
    private static Process ReadOwnerProcess(string identity)
    {
        // This immutable record belongs to the mutex owner. A process handle and
        // start time prevent PID reuse from selecting another application.
        for (int attempt = 0; attempt < 50; attempt++)
        {
            try
            {
                using (var owner = MemoryMappedFile.OpenExisting(identity + "-process", MemoryMappedFileRights.Read))
                using (var record = owner.CreateViewAccessor(0, 16, MemoryMappedFileAccess.Read))
                {
                    int pid = record.ReadInt32(0);
                    long started = record.ReadInt64(8);
                    if (pid > 0)
                    {
                        Process process;
                        try { process = Process.GetProcessById(pid); }
                        catch (ArgumentException) { return null; }
                        try
                        {
                            // Open and retain the kernel handle before signaling.
                            IntPtr handle = process.Handle;
                            if (process.StartTime.ToUniversalTime().Ticks != started ||
                                !String.Equals(FullPath(process.MainModule.FileName), FullPath(Assembly.GetExecutingAssembly().Location), StringComparison.OrdinalIgnoreCase))
                                throw new IOException("The watcher owner record does not match its process.");
                            return process;
                        }
                        catch (InvalidOperationException) { process.Dispose(); return null; }
                        catch { process.Dispose(); throw; }
                    }
                }
            }
            catch (FileNotFoundException) { }
            Thread.Sleep(20);
        }
        return null;
    }
    private static int Control(string mode, string identity)
    {
        if (mode == "--status")
        {
            try { using (var ready = EventWaitHandle.OpenExisting(identity + "-ready")) return ready.WaitOne(0) ? 0 : 1; }
            catch (WaitHandleCannotBeOpenedException) { return 1; }
        }
        try
        {
            using (var mutex = Mutex.OpenExisting(identity + "-owner"))
            using (var process = ReadOwnerProcess(identity))
            {
                if (process == null)
                {
                    bool inactive;
                    try { inactive = mutex.WaitOne(0); } catch (AbandonedMutexException) { inactive = true; }
                    if (!inactive) throw new IOException("The active watcher owner could not be identified; teardown was stopped.");
                    mutex.ReleaseMutex();
                    return 0;
                }
                var deadline = Stopwatch.StartNew();
                using (var stop = new EventWaitHandle(false, EventResetMode.ManualReset, identity + "-stop"))
                {
                    stop.Set();
                    bool owned;
                    try { owned = mutex.WaitOne(BurstMilliseconds); } catch (AbandonedMutexException) { owned = true; }
                    if (!owned) throw new IOException("The owned watcher did not finish its active repair within the stop deadline.");
                    mutex.ReleaseMutex();
                    if (process != null && !process.WaitForExit(Math.Max(1, BurstMilliseconds - (int)deadline.ElapsedMilliseconds)))
                        throw new IOException("The owned watcher has not exited after releasing its repair lock.");
                    return 0;
                }
            }
        }
        catch (WaitHandleCannotBeOpenedException) { return 0; }
    }
    private static int Main(string[] args)
    {
        try
        {
            if (args.Length < 2 || (args[0] != "--run" && args[0] != "--stop" && args[0] != "--status"))
                throw new ArgumentException("Usage: agy-watcher.exe --run PREFIX SHIM TARGET | --stop PREFIX | --status PREFIX");
            prefix = FullPath(args[1]);
            string executable = FullPath(Assembly.GetExecutingAssembly().Location);
            if (!String.Equals(executable, FullPath(Path.Combine(prefix, "agy-watcher.exe")), StringComparison.OrdinalIgnoreCase))
                throw new IOException("Watcher executable does not belong to this installation prefix.");
            AssertUnlinked(prefix);
            string identity = Identity();
            return args[0] == "--run" ? Run(args, identity) : Control(args[0], identity);
        }
        catch (Exception error)
        {
            Console.Error.WriteLine("[watcher] " + error.Message);
            try { if (prefix != null) Log(error.Message); } catch (IOException) { }
            return 1;
        }
    }
}
'@
Say "4/6 Native EXE shim for agy (automatic format detection)"
$supportPath = Join-Path $PREFIX "windows-support.ps1"
$launcherSourcePath = Join-Path $PREFIX "windows-launcher.cs"
# Load the new lifecycle helpers before touching files a previous watcher uses.
. ([scriptblock]::Create($windowsSupportSource))
Stop-AgyWindowsWatcher -Prefix $PREFIX
WriteBom $supportPath $windowsSupportSource
WriteNoBom $launcherSourcePath $windowsLauncherSource
$watcherSourcePath = Join-Path $PREFIX 'windows-watcher.cs'
WriteNoBom $watcherSourcePath $windowsWatcherSource
$watcherExecutable = Get-AgyWatcherExecutable -Prefix $PREFIX -SourcePath $watcherSourcePath
$shimState = Install-AgyWindowsShim -Prefix $PREFIX -Port $PORT -Certificate $ca -SourcePath $launcherSourcePath
if ($shimState) { Say "native shim installed: $($shimState.shimPath) -> $($shimState.target)" }

# --- heal ------------------------------------------------------------------
Say "5/6 Shim self-healing (filesystem events + task every 5 minutes)"
$healPs1 = @'
param([switch]$Watcher)
$ErrorActionPreference = "Stop"
$PREFIX = '@PREFIX@'
try {
  . (Join-Path $PREFIX "windows-support.ps1")
  if ($Watcher) {
    $result = Repair-AgyWindowsShim -Prefix $PREFIX -Watcher
    switch ($result) {
      'Healthy' { exit 0 }
      'Repaired' { exit 10 }
      'Pending' { exit 20 }
      'Blocked' { exit 21 }
      default { throw "Unexpected watcher repair result: $result" }
    }
  }
  Repair-AgyWindowsShim -Prefix $PREFIX
} catch {
  if ($Watcher) {
    [Console]::Error.WriteLine("[heal] " + $_.Exception.Message)
    exit 21
  }
  Add-Content -LiteralPath (Join-Path $PREFIX "mitm.log") -Value "[heal] $_" -Encoding UTF8
  exit 1
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
$ErrorActionPreference = "Stop"
$PREFIX = '@PREFIX@'
try {
  . (Join-Path $PREFIX "windows-support.ps1")
  Stop-AgyWindowsWatcher -Prefix $PREFIX
} catch {
  Write-Error "Could not stop self-healing; installation files were preserved: $_"
  exit 1
}
Remove-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" -Name "agy-region-fixer" -ErrorAction SilentlyContinue
foreach ($taskName in @('agy-region-fixer-watch', 'agy-region-fixer-heal')) {
  $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
  if ($task) { Unregister-ScheduledTask -InputObject $task -Confirm:$false -ErrorAction Stop }
}
$venvMitm = Join-Path $PREFIX "venv\Scripts\mitmdump.exe"
# @STOP_PROXY@
Stop-OurProxy
try {
  . (Join-Path $PREFIX "windows-support.ps1")
  Remove-AgyWindowsShim -Prefix $PREFIX
} catch {
  Write-Error "Could not restore agy; installation files were preserved: $_"
  exit 1
}
try {
  Remove-Item -Recurse -Force -LiteralPath $PREFIX -ErrorAction Stop
  if (Test-Path -LiteralPath $PREFIX) { throw "The installation directory still exists." }
} catch {
  Write-Error "Removal is incomplete; remaining files are in ${PREFIX}: $_"
  exit 1
}
Write-Host "Fully removed."
'@
$unPs1 = $unPs1.Replace("@PREFIX@", $PREFIX.Replace("'", "''")).Replace("# @STOP_PROXY@", ("function Stop-OurProxy {`r`n" + ${function:Stop-OurProxy}.ToString() + "`r`n}"))
WriteBom (Join-Path $PREFIX "uninstall.ps1") $unPs1

# Registration can be denied by local task policy; recovery must already exist.
Start-AgyWindowsWatcher -Prefix $PREFIX -State $shimState

# --- smoke -----------------------------------------------------------------
# hard 120 s limit: the process is started separately and the whole tree is killed on timeout
# (native shim -> original CLI or launcher); otherwise a hung request or a wait for login
# would block the install forever
$SMOKE_TIMEOUT_MS = 120000
function Test-SmokeSuccess($exitCode, $lines) {
  if ($exitCode -ne 0) { return $false }
  $replies = @($lines | ForEach-Object { ($_ -replace '\x1b\[[0-?]*[ -/]*[@-~]', '').Trim() } | Where-Object { $_ -ceq 'BYPASS_OK' })
  return $replies.Count -gt 0
}
$smokeCmd = Get-Command agy -ErrorAction SilentlyContinue
if ($smokeCmd) {
  Say "Smoke test: agy -p (up to 120 s)"
  $smokeOut = [IO.Path]::GetTempFileName()
  $smokeErr = [IO.Path]::GetTempFileName()
  $proc = $null
  try {
    $proc = Start-Process -FilePath $smokeCmd.Source -ArgumentList @("-p", "`"Reply exactly: BYPASS_OK`"") `
      -NoNewWindow -PassThru -RedirectStandardOutput $smokeOut -RedirectStandardError $smokeErr
    if ($proc.WaitForExit($SMOKE_TIMEOUT_MS)) {
      # stdout first: the model's answer is there; stderr is only a fallback source for the message
      $outLines = @(Get-Content -LiteralPath $smokeOut -ErrorAction SilentlyContinue | Where-Object { $_ })
      $errLines = @(Get-Content -LiteralPath $smokeErr -ErrorAction SilentlyContinue | Where-Object { $_ })
      if (Test-SmokeSuccess $proc.ExitCode @($outLines + $errLines)) { Say "OK — model replied: BYPASS_OK — bypass works" }
      else {
        $last = @($outLines + $errLines) | Select-Object -Last 1
        Say "agy did not reply BYPASS_OK: $last (did you log in? log: $PREFIX\mitm.log)"
      }
    } else {
      taskkill /T /F /PID $proc.Id 2>&1 | Out-Null
      Say "smoke did not finish in 120 s — aborted (did you log in? log: $PREFIX\mitm.log)"
    }
  } catch { Say "smoke failed: $_" }
  finally {
    try {
      # Ctrl+C also runs finally: stop only the process tree started by this smoke.
      if ($proc -and -not $proc.HasExited) { taskkill /T /F /PID $proc.Id 2>&1 | Out-Null }
    } catch { Say "could not stop smoke process $($proc.Id): $_" }
    finally { Remove-Item -LiteralPath $smokeOut, $smokeErr -Force -ErrorAction SilentlyContinue }
  }
}

Say "Done. Proxy: 127.0.0.1:$PORT | log: $PREFIX\mitm.log | uninstall: powershell $PREFIX\uninstall.ps1"
exit 0   # a successful install always returns 0; a smoke warning must not fail the exit code
