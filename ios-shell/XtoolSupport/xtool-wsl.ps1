[CmdletBinding()]
param(
    [ValidateSet('Preflight', 'Build')][string]$Mode = 'Preflight',
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_.-]*$')][string]$WslDistribution = 'Zeeho-iOS',
    [ValidateSet('DashboardIOS', 'SwiftProbe')][string]$Product = 'DashboardIOS',
    [string]$KmpXCFramework,
    [string]$KmpManifest,
    [string]$SwiftSDKRoot,
    [string]$OutputDirectory,
    [string]$BuildNumber,
    [string]$PythonPath,
    [switch]$AsJson
)
# 只调用显式 distro；不安装/重启/shutdown/login，永不使用默认 WSL distro。
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$shellRoot = Join-Path $root 'ios-shell'

function Invoke-Tool([string]$File, [string[]]$Arguments) {
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $lines = @(& $File @Arguments 2>&1)
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $previous }
    return [pscustomobject]@{ code = $code; text = ($lines | ForEach-Object { [string]$_ }) -join "`n" }
}
function Invoke-WslList([string]$File) {
    # wsl --list 在 Windows PowerShell 5 输出 UTF-16；不要拿 OEM/GBK 解码后的乱码当 distro 名。
    $start = New-Object System.Diagnostics.ProcessStartInfo
    $start.FileName = $File
    $start.Arguments = '--list --quiet'
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = [System.Text.Encoding]::Unicode
    $start.StandardErrorEncoding = [System.Text.Encoding]::Unicode
    $process = [System.Diagnostics.Process]::Start($start)
    $text = $process.StandardOutput.ReadToEnd() + $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    $code = $process.ExitCode
    $process.Dispose()
    return [pscustomobject]@{ code = $code; text = $text }
}
function Wsl-Path([string]$Path) {
    $path = [System.IO.Path]::GetFullPath($Path).Replace('\', '/')
    if ($path -notmatch '^([A-Za-z]):/(.*)$') { throw 'WSL input paths must be absolute local drive paths; UNC/remote paths are unsupported.' }
    return '/mnt/' + $Matches[1].ToLowerInvariant() + '/' + $Matches[2]
}
function Sdk-Path([string]$Path, [bool]$Linux) {
    if ($Linux -and $Path.StartsWith('/')) { return $Path }
    if ($Linux) { return Wsl-Path $Path }
    if ($Path.StartsWith('/')) { return $null }  # Windows fallback 不声称已验证 WSL 内路径。
    return [System.IO.Path]::GetFullPath($Path)
}
function Write-Json([string]$Path, $Value) {
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 16) + "`n", $encoding)
}

function Assert-Output([string]$Path) {
    $full = [System.IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    $component = $full
    while ($component) {
        if (Test-Path -LiteralPath $component) {
            $item = Get-Item -LiteralPath $component -Force
            if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'OUTPUT_DIRECTORY_FORBIDDEN: output cannot traverse junctions/links.' }
        }
        $component = [System.IO.Path]::GetDirectoryName($component)
    }
    $source = $root.TrimEnd('\', '/')
    $prefix = $source + [System.IO.Path]::DirectorySeparatorChar
    if ($full.Equals($source, [System.StringComparison]::OrdinalIgnoreCase) -or $source.StartsWith($full + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'OUTPUT_DIRECTORY_FORBIDDEN: source root/parent is not an artifact directory.'
    }
    $inside = $full.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)
    if ($inside) {
        $allowed = $false
        foreach ($relative in @('ios-shell\dist', 'ios-shell\.build-local')) {
            $base = Join-Path $root $relative
            if ($full.Equals($base, [System.StringComparison]::OrdinalIgnoreCase) -or $full.StartsWith($base + '\', [System.StringComparison]::OrdinalIgnoreCase)) { $allowed = $true }
        }
        if (-not $allowed) { throw 'OUTPUT_DIRECTORY_FORBIDDEN: source children such as Shared/Widgets/public are not output directories.' }
    }
    if (Test-Path -LiteralPath $full) {
        if (-not (Test-Path -LiteralPath $full -PathType Container)) { throw 'OUTPUT_DIRECTORY_FORBIDDEN: output is not a directory.' }
        foreach ($file in (Get-ChildItem -LiteralPath $full -Force)) {
            if ($file.Name -match '\.(app|appex|ipa)$' -or $file.Name -in @('xtool-build-manifest.json', 'version.json', 'build-manifest.json')) {
                throw 'OUTPUT_ARTIFACT_EXISTS: choose a fresh output directory; examined artifacts are never overwritten.'
            }
            if (-not $inside -and ($file.PSIsContainer -or $file.Name -notin @('xtool-preflight.json', 'xtool-blocked.log', 'xtool-build.log'))) {
                throw 'OUTPUT_DIRECTORY_FORBIDDEN: external output must be new/empty or contain only task blocking logs.'
            }
        }
    }
    return $full
}
if ($Mode -eq 'Build') {
    if (-not $OutputDirectory) { $OutputDirectory = Join-Path $shellRoot ('dist\xtool\' + $Product) }
    $OutputDirectory = Assert-Output $OutputDirectory
}

$checks = New-Object System.Collections.Generic.List[object]
$reasons = New-Object System.Collections.Generic.List[string]
$tools = [ordered]@{}
function Check([string]$Name, [bool]$OK, [string]$Detail) {
    $checks.Add([pscustomobject]@{ name = $Name; available = $OK; required = $true; detail = $Detail })
    if (-not $OK) { $reasons.Add($Name) }
}
$wslCommand = Get-Command wsl.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
$wsl = if ($wslCommand) { $wslCommand.Source } else { $null }
$list = if ($wsl) { Invoke-WslList $wsl } else { [pscustomobject]@{ code = 127; text = 'wsl.exe not installed' } }
$listText = $list.text.Replace([string][char]0, '')
$exists = $list.code -eq 0 -and @($listText -split "`r?`n" | ForEach-Object { $_.Trim() }) -contains $WslDistribution
$tools.wslList = $listText
Check 'WSL_NOT_READY' $exists ('Required named distro: ' + $WslDistribution + '. ' + $listText + ' If Windows features were just enabled, a user-controlled restart is required first; no distro is installed by this script.')
$outcomePath = Join-Path (Split-Path -Parent $root) 'environment\control\wsl-setup-outcome.json'
if (-not $exists -and (Test-Path -LiteralPath $outcomePath -PathType Leaf)) {
    try {
        $outcome = [System.IO.File]::ReadAllText($outcomePath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
        if ($outcome.PSObject.Properties.Name -contains 'restartRequired' -and $outcome.restartRequired -eq $true) {
            Check 'WSL_RESTART_REQUIRED' $false 'Recorded Windows feature setup requires a user-controlled restart. No kernel/distro installation or reboot is performed here.'
        }
    } catch { $tools.wslSetupOutcome = 'Could not read the local setup outcome; no setup status is assumed.' }
}
$status = $null
if ($exists) {
    $launch = Invoke-Tool $wsl @('--distribution', $WslDistribution, '--exec', '/bin/bash', '-lc', 'uname -s')
    Check 'WSL_LINUX_NOT_RUNNING' ($launch.code -eq 0 -and $launch.text.Trim() -eq 'Linux') $launch.text
    if ($launch.code -eq 0 -and $launch.text.Trim() -eq 'Linux') {
        $arguments = @('--distribution', $WslDistribution, '--exec', '/bin/bash', '-l', (Wsl-Path (Join-Path $shellRoot 'build-xtool.sh')), '--preflight-only', '--product', $Product)
        if ($KmpXCFramework) { $arguments += @('--xcframework', (Wsl-Path $KmpXCFramework)) }
        if ($KmpManifest) { $arguments += @('--kmp-manifest', (Wsl-Path $KmpManifest)) }
        if ($SwiftSDKRoot) { $arguments += @('--sdk-root', (Sdk-Path $SwiftSDKRoot $true)) }
        $read = Invoke-Tool $wsl $arguments
        try { $status = $read.text | ConvertFrom-Json } catch { Check 'XTOOL_PREFLIGHT_FAILED' $false $read.text }
        if ($status) {
            foreach ($item in $status.checks) { $checks.Add($item) }
            foreach ($reason in $status.reasons) { $reasons.Add([string]$reason) }
            $tools.linux = $status.tools
        }
    }
}
if (-not $status) {
    # WSL 尚不能运行时，用可信本地 Python -I 做相同源码/KMP诊断；这不是 Linux 编译通过。
    if (-not $PythonPath) {
        $python = Get-Command python.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($python -and $python.Source -notmatch '\\WindowsApps\\') { $PythonPath = $python.Source }
        if (-not $PythonPath) { $PythonPath = Join-Path $env:LOCALAPPDATA 'Programs\Python\Python312\python.exe' }
    }
    if (Test-Path -LiteralPath $PythonPath -PathType Leaf) {
        $arguments = @('-I', (Join-Path $PSScriptRoot 'xtool-support.py'), 'preflight', '--root', $root, '--product', $Product)
        if ($KmpXCFramework) { $arguments += @('--xcframework', [System.IO.Path]::GetFullPath($KmpXCFramework)) }
        if ($KmpManifest) { $arguments += @('--kmp-manifest', [System.IO.Path]::GetFullPath($KmpManifest)) }
        if ($SwiftSDKRoot) {
            $sdkPath = Sdk-Path $SwiftSDKRoot $false
            if ($sdkPath) { $arguments += @('--sdk-root', $sdkPath) }
        }
        $read = Invoke-Tool $PythonPath $arguments
        try { $status = $read.text | ConvertFrom-Json } catch { Check 'LOCAL_DIAGNOSTIC_FAILED' $false $read.text }
        if ($status) {
            $tools.windowsDiagnostic = $status.tools
            foreach ($item in $status.checks) { $checks.Add($item) }
            foreach ($reason in $status.reasons) { $reasons.Add([string]$reason) }
        }
    } else { Check 'PYTHON_MISSING' $false 'Provide existing Python 3.9+ for local source/KMP diagnostics.' }
    if (-not $status) {
        Check 'XTOOL_NOT_AVAILABLE' $false 'xtool in Zeeho-iOS has not been checked because the distro cannot run.'
        Check 'NO_SDK' $false 'No usable darwin SDK verified; the current user has no SDK.'
        if ($Product -eq 'DashboardIOS') { Check 'KMP_FRAMEWORK_MISSING' $false 'No real Apple ZeehoShared.xcframework has been supplied.' }
    }
}
$result = [pscustomobject]@{
    schemaVersion = 1; mode = $Mode; backend = 'xtool'; product = $Product
    wslDistribution = $WslDistribution; windowsSource = $root; wslSource = Wsl-Path $root
    readyForRequestedMode = $reasons.Count -eq 0; reasons = @($reasons.ToArray()); checks = @($checks.ToArray())
    tools = $tools; linuxToolchainVerified = $exists -and $tools.Contains('linux')
    authenticationAttempted = $false; deviceInstalled = $false; appleCryptographicVerification = $false
    notice = 'No tool/SDK/distro installation, reboot, WSL shutdown, remote upload, Apple login or device install. NO_SDK/KMP missing always blocks; SwiftProbe is not the full app.'
}
$exitCode = if ($result.readyForRequestedMode) { 0 } else { 2 }
if ($Mode -eq 'Build') {
    $OutputDirectory = Assert-Output $OutputDirectory
    if (-not $result.readyForRequestedMode) {
        [void][System.IO.Directory]::CreateDirectory($OutputDirectory)
        Write-Json (Join-Path $OutputDirectory 'xtool-preflight.json') $result
        $encoding = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText((Join-Path $OutputDirectory 'xtool-blocked.log'), 'BLOCKED: ' + ($result.reasons -join ', ') + "`n" + $result.notice + "`n", $encoding)
    } else {
        $arguments = @('--distribution', $WslDistribution, '--exec', '/bin/bash', '-l', (Wsl-Path (Join-Path $shellRoot 'build-xtool.sh')), '--product', $Product, '--output-dir', (Wsl-Path $OutputDirectory))
        if ($KmpXCFramework) { $arguments += @('--xcframework', (Wsl-Path $KmpXCFramework)) }
        if ($KmpManifest) { $arguments += @('--kmp-manifest', (Wsl-Path $KmpManifest)) }
        if ($SwiftSDKRoot) { $arguments += @('--sdk-root', (Sdk-Path $SwiftSDKRoot $true)) }
        if ($BuildNumber) { $arguments += @('--build-number', $BuildNumber) }
        $built = Invoke-Tool $wsl $arguments
        Write-Host $built.text
        $exitCode = $built.code
    }
}
if ($AsJson) { $result | ConvertTo-Json -Depth 16 } else {
    foreach ($check in $result.checks) {
        $label = if ($check.available) { 'OK' } elseif ($check.required) { 'BLOCKED' } else { 'UNVERIFIED' }
        Write-Output ('[' + $label + '] ' + $check.name + ' - ' + $check.detail)
    }
    Write-Output $result.notice
}
exit $exitCode
