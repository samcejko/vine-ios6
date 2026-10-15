# Helpers for testing Revine on the jailbroken iPad over SSH (dot-source this file).
#   . .\tools\ipad.ps1
#   Test-IPadIdle                      (another session or the user may be using the iPad: check first)
#   Install-VineIpa -IpaPath "$env:USERPROFILE\Downloads\Vine 2.5.1.ipa"
#   Install-RevineDeb -DebPath .\packages\run-123\com.samcejko.revine_0.1.0_iphoneos-arm.deb
#   Get-RevineLog
#   Get-VineCrashLogs
# Vine's executable is called "iphone", its bundle id is com.vine.iphone.

$script:IPadKey = Join-Path $env:USERPROFILE '.ssh\ipad_ios6'
$script:IPadDefaultHost = '192.168.1.176'
$script:IPadLocalCfg = Join-Path $PSScriptRoot 'local.json'
if (Test-Path $script:IPadLocalCfg) {
    try {
        $c = Get-Content $script:IPadLocalCfg -Raw | ConvertFrom-Json
        if ($c.ipad) { $script:IPadDefaultHost = $c.ipad }
    } catch {}
}

function Get-IPadSshArgs {
    # (keepalives end a session whose Wi-Fi link died instead of waiting for ever)
    @('-i', $script:IPadKey, '-oHostKeyAlgorithms=+ssh-rsa', '-oStrictHostKeyChecking=accept-new', '-oConnectTimeout=10', '-oBatchMode=yes', '-oLogLevel=ERROR',
      '-oServerAliveInterval=5', '-oServerAliveCountMax=4')
}

# Runs a command on the iPad and returns stdout+stderr as plain strings (never throws on stderr output).
function Invoke-IPad {
    param([Parameter(Mandatory = $true)][string]$Command, [string]$IPadHost = $script:IPadDefaultHost)
    $ErrorActionPreference = 'Continue'   # function-local: native stderr must not become a terminating error
    $sshArgs = Get-IPadSshArgs
    & ssh.exe @sshArgs "root@$IPadHost" $Command 2>&1 |
        ForEach-Object { if ($_ -is [Management.Automation.ErrorRecord]) { $_.Exception.Message } else { $_ } }
}

function Copy-ToIPad {
    param([Parameter(Mandatory = $true)][string]$LocalPath, [Parameter(Mandatory = $true)][string]$RemotePath, [string]$IPadHost = $script:IPadDefaultHost)
    $ErrorActionPreference = 'Continue'
    $sshArgs = Get-IPadSshArgs
    & scp.exe -O @sshArgs $LocalPath "root@${IPadHost}:$RemotePath" 2>&1 |
        ForEach-Object { if ($_ -is [Management.Automation.ErrorRecord]) { $_.Exception.Message } else { $_ } }
    if ($LASTEXITCODE -ne 0) { throw "scp failed for $LocalPath" }
}

function Copy-FromIPad {
    param([Parameter(Mandatory = $true)][string]$RemotePath, [Parameter(Mandatory = $true)][string]$LocalPath, [string]$IPadHost = $script:IPadDefaultHost)
    $ErrorActionPreference = 'Continue'
    $sshArgs = Get-IPadSshArgs
    & scp.exe -O @sshArgs -r "root@${IPadHost}:$RemotePath" $LocalPath 2>&1 |
        ForEach-Object { if ($_ -is [Management.Automation.ErrorRecord]) { $_.Exception.Message } else { $_ } }
    if ($LASTEXITCODE -ne 0) { throw "scp failed for $RemotePath" }
}

# Which apps run in the foreground/background right now: another test session or the user may be busy on the iPad
function Test-IPadIdle {
    param([string]$IPadHost = $script:IPadDefaultHost)
    Invoke-IPad -IPadHost $IPadHost -Command "launchctl list | grep UIKitApplication; echo ---; grep -c . /var/log/syslog 2>/dev/null"
}

# Installs the Vine IPA the user supplies (needs AppSync and ipainstaller on the iPad)
function Install-VineIpa {
    param([Parameter(Mandatory = $true)][string]$IpaPath, [string]$IPadHost = $script:IPadDefaultHost)
    Copy-ToIPad -LocalPath $IpaPath -RemotePath '/tmp/Vine.ipa' -IPadHost $IPadHost
    $out = Invoke-IPad -IPadHost $IPadHost -Command 'if command -v ipainstaller >/dev/null 2>&1; then ipainstaller -f /tmp/Vine.ipa; echo "IPA_EXIT=$?"; else echo NO_INSTALLER; fi; rm -f /tmp/Vine.ipa' | Out-String
    Write-Host $out
    if (-not ($out -match 'IPA_EXIT=0' -or $out -match '(?i)installed .* successfully')) { throw "Vine was not installed" }
}

function Install-RevineDeb {
    param([Parameter(Mandatory = $true)][string]$DebPath, [string]$IPadHost = $script:IPadDefaultHost)
    Invoke-IPad -IPadHost $IPadHost -Command 'killall iphone 2>/dev/null; echo stopped' | Out-Null
    Copy-ToIPad -LocalPath $DebPath -RemotePath '/tmp/Revine.deb' -IPadHost $IPadHost
    $out = Invoke-IPad -IPadHost $IPadHost -Command 'dpkg -i /tmp/Revine.deb 2>&1 && echo DEB_OK; rm -f /tmp/Revine.deb' | Out-String
    Write-Host $out
    if ($out -notmatch 'DEB_OK') { throw "Revine was not installed" }
    Write-Host "Done. Open Vine on the iPad (no respring needed: the tweak loads when Vine starts)."
}

# The tweak's own log lines ([Revine] prefix), the last $Lines of them
function Get-RevineLog {
    param([int]$Lines = 60, [string]$IPadHost = $script:IPadDefaultHost)
    Invoke-IPad -IPadHost $IPadHost -Command "grep -e '\[Revine\]' -e 'iphone\[' /var/log/syslog | sed -e :a -e '`$q;N;$($Lines + 1),`$D;ba'"
}

function Get-VineCrashLogs {
    param([string]$IPadHost = $script:IPadDefaultHost, [string]$OutDir = '')
    if (-not $OutDir) { $OutDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'packages\crashlogs' }
    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
    # (the iPad has no head/tail/wc/awk; sed does their work)
    $list = Invoke-IPad -IPadHost $IPadHost -Command "ls -t /var/mobile/Library/Logs/CrashReporter/ 2>/dev/null | grep '^iphone_' | sed -n '1,5p'"
    foreach ($f in (@($list) -join "`n" -split "`n" | Where-Object { $_.Trim() })) {
        $name = $f.Trim()
        Copy-FromIPad -IPadHost $IPadHost -RemotePath "/var/mobile/Library/Logs/CrashReporter/$name" -LocalPath (Join-Path $OutDir $name)
        Write-Host "Fetched $name"
    }
    Get-ChildItem $OutDir -File | Sort-Object LastWriteTime -Descending | Select-Object -First 1
}

# Turns the test commands of src/RVDebug.m on or off (a root-owned file next to the tweak's support files)
function Set-RevineDebug {
    param([bool]$On = $true, [string]$IPadHost = $script:IPadDefaultHost)
    # (ssh.exe drops double quotes from the command line: the space is escaped instead)
    $cmd = if ($On) { 'touch /Library/Application\ Support/Revine/debug && echo DEBUG_ON' } else { 'rm -f /Library/Application\ Support/Revine/debug; echo DEBUG_OFF' }
    Invoke-IPad -IPadHost $IPadHost -Command $cmd
}

# A test command in the running Vine: dump, snapshot, press?x=&y=, tap?text=, type?n=&text=&submit=1, alert?n=, back, close
function Invoke-RevineDebug {
    param([Parameter(Mandatory = $true)][string]$Command, [int]$WaitSeconds = 2, [string]$IPadHost = $script:IPadDefaultHost)
    Invoke-IPad -IPadHost $IPadHost -Command "uiopen 'vine://revine/$Command'; sleep $WaitSeconds"
}

# The screen of Vine as a PNG (the tweak draws its windows into the app's tmp folder)
function Get-VineScreen {
    param([Parameter(Mandatory = $true)][string]$OutFile, [string]$IPadHost = $script:IPadDefaultHost)
    $app = (Invoke-IPad -IPadHost $IPadHost -Command "ls -d /var/mobile/Applications/*/iphone.app | sed -n '1p'" | Out-String).Trim()
    if (-not $app) { throw 'Vine is not installed' }
    $container = $app -replace '/iphone\.app$', ''
    Invoke-IPad -IPadHost $IPadHost -Command "rm -f '$container/tmp/screen.png'; uiopen 'vine://revine/snapshot'; sleep 3; cp '$container/tmp/screen.png' /tmp/vine-screen.png" | Out-Null
    Copy-FromIPad -IPadHost $IPadHost -RemotePath '/tmp/vine-screen.png' -LocalPath $OutFile
    Get-Item $OutFile
}

# Opens a vine:// link in the app (Vine's own navigation: popular-now, channels/<id>, user-id/<id>, post/<id>...)
function Invoke-VineLink {
    param([Parameter(Mandatory = $true)][string]$Url, [int]$WaitSeconds = 0, [string]$IPadHost = $script:IPadDefaultHost)
    $cmd = "uiopen '$Url'"
    if ($WaitSeconds -gt 0) { $cmd += "; sleep $WaitSeconds" }
    Invoke-IPad -IPadHost $IPadHost -Command $cmd
}
