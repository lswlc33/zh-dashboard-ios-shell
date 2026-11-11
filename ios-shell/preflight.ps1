[CmdletBinding()]
param(
    [ValidateSet('Preflight', 'Test', 'Build', 'XtoolPreflight', 'XtoolBuild')]
    [string]$Mode = 'Preflight',
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_.-]*$')]
    [string]$WslDistribution = 'Zeeho-iOS',
    [ValidateSet('DashboardIOS', 'SwiftProbe')]
    [string]$Product = 'DashboardIOS',
    [string]$KmpXCFramework,
    [string]$KmpManifest,
    [string]$SwiftSDKRoot,
    [string]$MacHost,
    [switch]$AllowSourceUpload,
    [string]$JavaHome = 'E:\Java\jdk-21.0.12.1+1',
    [string]$PythonPath,
    [string]$GradleUserHome,
    [switch]$AsJson
)
# 只读：不启动 Gradle、不下载工具、不探测 SSH 网络、不改全局配置。
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($Mode -in @('XtoolPreflight', 'XtoolBuild')) {
    if ($MacHost -or $AllowSourceUpload) { throw 'xtool preflight is local WSL-only; remote/upload parameters are not accepted.' }
    $arguments = @{ Mode = 'Preflight'; WslDistribution = $WslDistribution; Product = $Product }
    if ($KmpXCFramework) { $arguments.KmpXCFramework = $KmpXCFramework }
    if ($KmpManifest) { $arguments.KmpManifest = $KmpManifest }
    if ($SwiftSDKRoot) { $arguments.SwiftSDKRoot = $SwiftSDKRoot }
    if ($PythonPath) { $arguments.PythonPath = $PythonPath }
    if ($AsJson) { $arguments.AsJson = $true }
    & (Join-Path $PSScriptRoot 'XtoolSupport\xtool-wsl.ps1') @arguments
    exit $LASTEXITCODE
}
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$sharedRoot = Join-Path $repoRoot 'native-shared'
$checks = New-Object System.Collections.Generic.List[object]
$missing = New-Object System.Collections.Generic.List[string]

function Resolve-LocalTool([string]$Name, [string]$ExplicitPath = '') {
    if ($ExplicitPath) {
        if (Test-Path -LiteralPath $ExplicitPath -PathType Leaf) { return (Get-Item -LiteralPath $ExplicitPath).FullName }
        return $null
    }
    $command = Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) { return $command.Source }
    return $null
}
function Invoke-ReadOnlyCheck([string]$File, [string[]]$Arguments) {
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $lines = @(& $File @Arguments 2>&1)
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousPreference
    }
    return [pscustomobject]@{ code = $code; text = ($lines | ForEach-Object { [string]$_ }) -join "`n" }
}
function Add-Check([string]$Name, [bool]$Available, [string]$Detail, [bool]$Required = $true) {
    $checks.Add([pscustomobject]@{ name = $Name; available = $Available; detail = $Detail; required = $Required })
    if ($Required -and -not $Available) { $missing.Add($Name + ': ' + $Detail) }
}

$javaExecutable = Resolve-LocalTool 'java.exe' (Join-Path $JavaHome 'bin\java.exe')
$javaOK = $false
$javaVersion = ''
if ($javaExecutable) {
    # 用现有 JDK 可执行文件，无 Gradle/Apple 工具下载或安装副作用。
    $start = New-Object System.Diagnostics.ProcessStartInfo
    $start.FileName = $javaExecutable
    $start.Arguments = '-version'
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardError = $true
    $start.RedirectStandardOutput = $true
    $process = [System.Diagnostics.Process]::Start($start)
    $javaVersion = $process.StandardError.ReadToEnd() + $process.StandardOutput.ReadToEnd()
    $process.WaitForExit()
    $javaOK = $process.ExitCode -eq 0 -and $javaVersion -match 'version\s+"21(?:\.|\")'
    $process.Dispose()
}
Add-Check 'JDK 21' $javaOK $(if ($javaExecutable) { $javaExecutable + '; ' + $javaVersion.Trim() } else { 'Set -JavaHome to an existing JDK 21 directory; nothing is installed automatically.' })

$pythonExecutable = Resolve-LocalTool 'python.exe' $PythonPath
if (-not $PythonPath -and (-not $pythonExecutable -or $pythonExecutable -match '\\WindowsApps\\')) {
    $knownPython = Join-Path $env:LOCALAPPDATA 'Programs\Python\Python312\python.exe'
    if (Test-Path -LiteralPath $knownPython -PathType Leaf) { $pythonExecutable = $knownPython }
}
$pythonOK = $false
$pythonVersion = ''
if ($pythonExecutable -and $pythonExecutable -notmatch '\\WindowsApps\\') {
    $check = Invoke-ReadOnlyCheck $pythonExecutable @('-I', '-c', 'import sys; print(sys.version.split()[0]); sys.exit(0 if sys.version_info >= (3, 9) else 2)')
    $pythonVersion = $check.text.Trim()
    $pythonOK = $check.code -eq 0
}
Add-Check 'Python 3.9+' $pythonOK $(if ($pythonOK) { $pythonExecutable + '; ' + $pythonVersion } else { 'Provide -PythonPath to an existing Python; Microsoft Store aliases do not count as an installed interpreter.' })
$git = Resolve-LocalTool 'git.exe'
Add-Check 'Git' ([bool]$git) $(if ($git) { $git } else { 'Git must be installed already to record sourceCommit.' })

foreach ($relative in @(
    'native-shared\gradlew', 'native-shared\gradlew.bat',
    'native-shared\gradle\wrapper\gradle-wrapper.jar',
    'native-shared\gradle\wrapper\gradle-wrapper.properties',
    'native-shared\build.gradle.kts', 'native-shared\settings.gradle.kts',
    'ios-shell\Info.plist', 'ios-shell\build.sh', 'ios-shell\test.py',
    'ios-shell\build-support.py', 'ios-shell\bridge-bootstrap.js',
    'public\icons\icon-512.png'
)) {
    $path = Join-Path $repoRoot $relative
    Add-Check $relative (Test-Path -LiteralPath $path -PathType Leaf) $path
}
$sourceCheckOK = $false
if ($pythonOK -and $git -and (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'build-support.py') -PathType Leaf)) {
    $check = Invoke-ReadOnlyCheck $pythonExecutable @('-I', (Join-Path $PSScriptRoot 'build-support.py'), 'inputs', '--root', $repoRoot)
    $sourceCheckOK = $check.code -eq 0
    Add-Check 'Public source/KMP framework contract' $sourceCheckOK $(if ($sourceCheckOK) { 'UIKit Swift imports ZeehoShared; complete allowlisted inputs; source commit/hash readable.' } else { $check.text.Trim() })
}

$appleMissing = @(
    'macOS (Darwin) for the default Xcode backend; use explicit XtoolPreflight/XtoolBuild for WSL',
    'Full Xcode with iPhoneOS SDK and accepted license/first-launch setup',
    'Xcode xcrun/swiftc, swift-stdlib-tool, lipo and otool',
    'macOS codesign, plutil, sips, file, zip and /usr/libexec/PlistBuddy',
    'Kotlin/Native iOS compiler dependencies on that Mac; real :linkReleaseFrameworkIosArm64 output'
)
$remoteRequested = -not [string]::IsNullOrWhiteSpace($MacHost)
if ($remoteRequested) {
    Add-Check 'Explicit source upload opt-in' ([bool]$AllowSourceUpload) 'Remote build requires both -MacHost and -AllowSourceUpload. No preflight ever makes an SSH connection.' ($Mode -eq 'Build')
    $hostValid = $MacHost -match '^(?:[A-Za-z0-9_][A-Za-z0-9_.-]*@)?[A-Za-z0-9][A-Za-z0-9.-]*$'
    Add-Check 'SSH host syntax' $hostValid 'Use a host/config alias or user@host, not options or a command.'
    foreach ($tool in @('ssh.exe', 'scp.exe')) {
        $path = Resolve-LocalTool $tool
        Add-Check $tool ([bool]$path) $(if ($path) { $path } else { 'Use already-installed Windows OpenSSH; it is not installed automatically.' })
    }
    $knownHosts = Join-Path $env:USERPROFILE '.ssh\known_hosts'
    Add-Check 'Existing SSH host keys' (Test-Path -LiteralPath $knownHosts -PathType Leaf) 'An already trusted SSH host key must exist. StrictHostKeyChecking=yes is never relaxed.' ($Mode -eq 'Build')
    foreach ($item in $appleMissing) { Add-Check 'Unverified remote Apple requirement' $false $item $false }
} else {
    foreach ($item in $appleMissing) { Add-Check 'Local Apple requirement' $false $item ($Mode -ne 'Test') }
}
if ($AllowSourceUpload -and -not $remoteRequested) { Add-Check 'Upload destination' $false '-AllowSourceUpload alone never uploads; specify -MacHost for a future remote build.' }
if (-not $GradleUserHome) { $GradleUserHome = Join-Path $PSScriptRoot '.build-local\gradle-user-home' }
$GradleUserHome = [System.IO.Path]::GetFullPath($GradleUserHome)
$ready = $missing.Count -eq 0 -and $sourceCheckOK
$result = [pscustomobject]@{
    mode = $Mode
    readyForRequestedMode = $ready
    localAppleBuildSupported = $false
    remoteRequested = $remoteRequested
    remoteContacted = $false
    checks = @($checks.ToArray())
    missing = @($missing.ToArray())
    tools = [pscustomobject]@{ python = $pythonExecutable; java = $javaExecutable; git = $git }
    cacheLocations = [pscustomobject]@{
        gradleUserHome = $GradleUserHome
        gradleProjectCache = Join-Path $PSScriptRoot '.build-local\shared-project-cache'
        kotlinNative = Join-Path $PSScriptRoot '.build-local\konan'
        sharedBuild = Join-Path $sharedRoot 'build'
        iosOutput = Join-Path $PSScriptRoot 'dist'
    }
    notice = 'Read-only preflight. No SSH/SCP, compilation, signing, installation, restart, CI or archive export. Source/JVM checks never imply an Apple compile or device test.'
}
if ($AsJson) {
    $result | ConvertTo-Json -Depth 6
} else {
    Write-Output ('Mode: ' + $Mode + '; local Apple build: unsupported; remote contacted: no')
    foreach ($check in $checks) {
        $label = if ($check.available) { 'OK' } elseif ($check.required) { 'BLOCKED' } else { 'NOT CHECKED' }
        Write-Output ('[' + $label + '] ' + $check.name + ' - ' + $check.detail)
    }
    Write-Output $result.notice
    Write-Output ('Local caches, only when Test is explicitly run: ' + $result.cacheLocations.gradleUserHome)
}
if (-not $ready) { exit 2 }
exit 0
