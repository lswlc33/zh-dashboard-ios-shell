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
    [string]$OutputDirectory,
    [ValidatePattern('^[1-9][0-9]*$')]
    [string]$BuildNumber,
    [ValidateRange(1, 65535)]
    [int]$SshPort = 22,
    [string]$SshIdentityFile,
    [switch]$Offline
)
# 默认只读且不联络任何主机。远程只能由 -Mode Build -MacHost -AllowSourceUpload 同时选择。
# 本机 Test 仅使用现有缓存 --offline；不安装 Xcode/JDK/Gradle，不恢复 GitHub Actions。
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($Mode -in @('XtoolPreflight', 'XtoolBuild')) {
    if ($MacHost -or $AllowSourceUpload -or $SshIdentityFile) { throw 'xtool is local WSL-only; remote/upload parameters are not accepted.' }
    $arguments = @{ Mode = $(if ($Mode -eq 'XtoolBuild') { 'Build' } else { 'Preflight' }); WslDistribution = $WslDistribution; Product = $Product }
    if ($KmpXCFramework) { $arguments.KmpXCFramework = $KmpXCFramework }
    if ($KmpManifest) { $arguments.KmpManifest = $KmpManifest }
    if ($SwiftSDKRoot) { $arguments.SwiftSDKRoot = $SwiftSDKRoot }
    if ($OutputDirectory) { $arguments.OutputDirectory = $OutputDirectory }
    if ($BuildNumber) { $arguments.BuildNumber = $BuildNumber }
    if ($PythonPath) { $arguments.PythonPath = $PythonPath }
    & (Join-Path $PSScriptRoot 'XtoolSupport\xtool-wsl.ps1') @arguments
    exit $LASTEXITCODE
}
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$sharedRoot = Join-Path $repoRoot 'native-shared'
$support = Join-Path $PSScriptRoot 'build-support.py'
$preflight = Join-Path $PSScriptRoot 'preflight.ps1'
$localStage = $null
$remoteRoot = $null
$ssh = $null
$sshArguments = @()
$exitCode = 2

function Invoke-LocalTool {
    param([string]$File, [string[]]$Arguments, [string]$InputText, [switch]$Capture)
    # PowerShell 5 的原生 stderr 不应把命令退出码隐藏成 PowerShell 格式错误。
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        if ($PSBoundParameters.ContainsKey('InputText')) {
            $lines = @($InputText | & $File @Arguments 2>&1)
        } else {
            $lines = @(& $File @Arguments 2>&1)
        }
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousPreference
    }
    if ($code -ne 0) {
        foreach ($line in $lines) { Write-Host ([string]$line) }
        throw ('Command failed with exit ' + $code + ': ' + [System.IO.Path]::GetFileName($File))
    }
    if ($Capture) { return ($lines | ForEach-Object { [string]$_ }) -join "`n" }
    foreach ($line in $lines) { Write-Host ([string]$line) }
}
function Find-OpenSsh([string]$Name) {
    $windowsOpenSsh = Join-Path $env:WINDIR ('System32\OpenSSH\' + $Name)
    if (Test-Path -LiteralPath $windowsOpenSsh -PathType Leaf) { return $windowsOpenSsh }
    $command = Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) { return $command.Source }
    throw ('Missing existing OpenSSH tool: ' + $Name)
}
function Write-Utf8Script([string]$Path, [string]$Text) {
    # bash 脚本写成 UTF-8 无 BOM、LF；脚本与任何 ZIP/解压数据目录分开。
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Text.Replace("`r`n", "`n"), $encoding)
}

try {
    if ($Mode -eq 'Test' -and ($MacHost -or $AllowSourceUpload)) { throw 'Test is local-only. MacHost/upload parameters are only for an explicit future Build.' }
    if ($SshIdentityFile -and (-not $MacHost -or $Mode -ne 'Build')) { throw 'SshIdentityFile is only for an explicitly chosen remote Build; it is never uploaded.' }
    $preflightArguments = @{ Mode = $Mode; JavaHome = $JavaHome; AsJson = $true }
    if ($PythonPath) { $preflightArguments.PythonPath = $PythonPath }
    if ($GradleUserHome) { $preflightArguments.GradleUserHome = $GradleUserHome }
    if ($MacHost) { $preflightArguments.MacHost = $MacHost }
    if ($AllowSourceUpload) { $preflightArguments.AllowSourceUpload = $true }
    # 在子作用域执行只读 preflight；exit 不会终止调用者的 PowerShell 会话。
    $jsonText = (& $preflight @preflightArguments | Out-String)
    $preflightExit = $LASTEXITCODE
    $status = $jsonText | ConvertFrom-Json
    foreach ($check in $status.checks) {
        $label = if ($check.available) { 'OK' } elseif ($check.required) { 'BLOCKED' } else { 'NOT CHECKED' }
        Write-Host ('[' + $label + '] ' + $check.name + ' - ' + $check.detail)
    }
    Write-Host $status.notice
    if ($Mode -eq 'Preflight' -or $preflightExit -ne 0 -or -not $status.readyForRequestedMode) {
        $exitCode = $preflightExit
        if (-not $status.readyForRequestedMode) { $exitCode = 2 }
    } elseif ($Mode -eq 'Test') {
        $python = $status.tools.python
        Invoke-LocalTool -File $python -Arguments @('-I', (Join-Path $PSScriptRoot 'test.py'))
        $testSources = @()
        foreach ($sourceSet in @('commonTest', 'jvmTest')) {
            $testPath = Join-Path $sharedRoot ('src\' + $sourceSet + '\kotlin')
            if (Test-Path -LiteralPath $testPath -PathType Container) { $testSources += @(Get-ChildItem -LiteralPath $testPath -Filter '*.kt' -File -Recurse) }
        }
        if ($testSources.Count -eq 0) { throw 'No real commonTest/jvmTest Kotlin sources were found; a NO-SOURCE task is not a passing test.' }
        if (-not $GradleUserHome) { $GradleUserHome = $status.cacheLocations.gradleUserHome }
        $GradleUserHome = [System.IO.Path]::GetFullPath($GradleUserHome)
        # gradlew --offline 仍会下载缺失的 wrapper distribution，故只使用已缓存的真实 Gradle。
        $wrapperProperties = Join-Path $sharedRoot 'gradle\wrapper\gradle-wrapper.properties'
        $properties = [System.IO.File]::ReadAllText($wrapperProperties, [System.Text.Encoding]::UTF8)
        $distribution = [regex]::Match($properties, '(?m)^distributionUrl=.*?/gradle-([0-9]+(?:\.[0-9]+)+)-(bin|all)\.zip\s*$')
        if (-not $distribution.Success) { throw 'Cannot locate a supported existing Gradle distribution from the real wrapper properties.' }
        $version = $distribution.Groups[1].Value
        $kind = $distribution.Groups[2].Value
        $distributionRoot = Join-Path $GradleUserHome ('wrapper\dists\gradle-' + $version + '-' + $kind)
        $cachedGradle = @()
        if (Test-Path -LiteralPath $distributionRoot -PathType Container) {
            foreach ($directory in (Get-ChildItem -LiteralPath $distributionRoot -Directory)) {
                $candidate = Join-Path $directory.FullName ('gradle-' + $version + '\bin\gradle.bat')
                if (Test-Path -LiteralPath $candidate -PathType Leaf) { $cachedGradle += $candidate }
            }
        }
        if ($cachedGradle.Count -eq 0) {
            throw ('Source checks passed, but JVM tests are blocked: no cached Gradle ' + $version + '. No wrapper/tool download was attempted. Use an existing -GradleUserHome cache.')
        }
        $previousJavaHome = $env:JAVA_HOME
        $previousPath = $env:PATH
        $previousGradleHome = $env:GRADLE_USER_HOME
        $previousKonan = $env:KONAN_DATA_DIR
        try {
            $env:JAVA_HOME = $JavaHome
            $env:PATH = (Join-Path $JavaHome 'bin') + [System.IO.Path]::PathSeparator + $env:PATH
            $env:GRADLE_USER_HOME = $GradleUserHome
            $env:KONAN_DATA_DIR = $status.cacheLocations.kotlinNative
            $projectCache = Join-Path $PSScriptRoot '.build-local\shared-project-cache'
            Invoke-LocalTool -File $cachedGradle[0] -Arguments @('--project-dir', $sharedRoot, '--project-cache-dir', $projectCache, '--no-daemon', '--offline', '--console=plain', ':jvmTest')
        } finally {
            $env:JAVA_HOME = $previousJavaHome
            $env:PATH = $previousPath
            $env:GRADLE_USER_HOME = $previousGradleHome
            $env:KONAN_DATA_DIR = $previousKonan
        }
        Write-Host 'Local UTF-8/source checks and real KMP JVM tests passed. No Swift/iOS compilation or device validation was performed.'
        $exitCode = 0
    } else {
        # 这一分支只能在用户同时明确给出 MacHost 和 AllowSourceUpload 后到达。
        if (-not $MacHost -or -not $AllowSourceUpload) { throw 'Local Apple Build is unsupported. A future remote build needs explicit -MacHost AND -AllowSourceUpload.' }
        $python = $status.tools.python
        $ssh = Find-OpenSsh 'ssh.exe'
        $scp = Find-OpenSsh 'scp.exe'
        $sshArguments = @('-o', 'StrictHostKeyChecking=yes', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=15', '-o', 'ServerAliveInterval=30', '-o', 'ServerAliveCountMax=3')
        $scpArguments = @('-o', 'StrictHostKeyChecking=yes', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=15')
        $sshArguments += @('-p', [string]$SshPort)
        $scpArguments += @('-P', [string]$SshPort)
        if ($SshIdentityFile) {
            if (-not (Test-Path -LiteralPath $SshIdentityFile -PathType Leaf)) { throw 'Existing SSH identity file was not found; it is never generated or uploaded.' }
            $identity = (Get-Item -LiteralPath $SshIdentityFile).FullName
            $sshArguments += @('-i', $identity)
            $scpArguments += @('-i', $identity)
        }
        if (-not $OutputDirectory) { $OutputDirectory = Join-Path $PSScriptRoot 'dist' }
        $OutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)
        Invoke-LocalTool -File $python -Arguments @('-I', $support, 'output-check', '--root', $repoRoot, '--output', $OutputDirectory)
        $localStage = Join-Path ([System.IO.Path]::GetTempPath()) ('zeeho-ios-transfer-' + [Guid]::NewGuid().ToString('N'))
        if (Test-Path -LiteralPath $localStage) { throw 'Staging directory already exists; refusing to reuse it.' }
        [void](New-Item -ItemType Directory -Path $localStage)
        $archiveDirectory = Join-Path $localStage 'archive'
        $controlDirectory = Join-Path $localStage 'control'
        $returnedDirectory = Join-Path $localStage 'returned'
        foreach ($directory in @($archiveDirectory, $controlDirectory, $returnedDirectory)) { [void](New-Item -ItemType Directory -Path $directory) }
        $sourceArchive = Join-Path $archiveDirectory 'sources.zip'
        $sourceManifest = Join-Path $controlDirectory 'source-manifest.json'
        # 只允许固定 iOS/KMP 公共源码与一个 icon；不归档全仓、真实账号、配置或构建缓存。
        Invoke-LocalTool -File $python -Arguments @('-I', $support, 'archive', '--root', $repoRoot, '--output', $sourceArchive, '--manifest', $sourceManifest)
        Copy-Item -LiteralPath $support -Destination (Join-Path $controlDirectory 'build-support.py')
        $remoteDriver = @'
#!/bin/bash
set -euo pipefail
work="$1"
build_number="$2"
offline="$3"
[[ "$work" =~ ^/private/tmp/zeeho-ios-remote\.[A-Za-z0-9]+$ ]] || exit 2
[[ "$(uname -s)" == Darwin ]] || { printf '%s\n' 'BLOCKED: remote host is not macOS.' >&2; exit 2; }
# 控制脚本与归档、解压目录分离。Python -I 不从 archive/source/cwd 加载同名模块。
cd "$work/control"
python3 -I "$work/control/build-support.py" extract --archive "$work/archive/sources.zip" --manifest "$work/control/source-manifest.json" --destination "$work/source"
args=(--source-manifest "$work/control/source-manifest.json" --output-dir "$work/artifacts")
if [[ -n "$build_number" ]]; then args+=(--build-number "$build_number"); fi
if [[ "$offline" == true ]]; then args+=(--offline); fi
bash "$work/source/ios-shell/build.sh" --preflight-only "${args[@]}"
bash "$work/source/ios-shell/build.sh" "${args[@]}"
'@
        Write-Utf8Script (Join-Path $controlDirectory 'remote-driver.sh') $remoteDriver
        $remoteInit = @'
set -euo pipefail
[[ "$(uname -s)" == Darwin ]] || { printf '%s\n' 'BLOCKED: MacHost is not macOS.' >&2; exit 2; }
missing=()
for tool in python3 java git xcrun xcodebuild codesign plutil sips zip file; do
    command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
done
[[ ${#missing[@]} -eq 0 ]] || { printf 'BLOCKED: missing existing remote tool: %s\n' "${missing[@]}" >&2; exit 2; }
xcrun --sdk iphoneos --show-sdk-path >/dev/null
xcodebuild -version >/dev/null
for tool in swiftc swift-stdlib-tool lipo otool; do xcrun --sdk iphoneos --find "$tool" >/dev/null; done
java_version="$(java -version 2>&1)"
[[ "$java_version" =~ version\ \"21[.\"] ]] || { printf '%s\n' 'BLOCKED: remote JDK21 is missing.' >&2; exit 2; }
python3 -I -c 'import sys; assert sys.version_info >= (3, 9), "Python 3.9+ required"'
work="$(mktemp -d /private/tmp/zeeho-ios-remote.XXXXXXXX)"
mkdir "$work/control" "$work/archive" "$work/source" "$work/artifacts"
printf '%s\n' "$work"
'@
        Write-Host 'Explicit remote build selected: strict SSH host-key verification; allowlisted source snapshot only.'
        $initOutput = Invoke-LocalTool -File $ssh -Arguments ($sshArguments + @('--', $MacHost, '/bin/bash -s')) -InputText $remoteInit -Capture
        $roots = @($initOutput -split "`n" | Where-Object { $_ -match '^/private/tmp/zeeho-ios-remote\.[A-Za-z0-9]+$' })
        if ($roots.Count -ne 1) { throw 'Remote did not return exactly one fresh, safe staging directory.' }
        $remoteRoot = $roots[0]
        Invoke-LocalTool -File $scp -Arguments ($scpArguments + @('--', $sourceArchive, ($MacHost + ':' + $remoteRoot + '/archive/sources.zip')))
        $controls = @((Join-Path $controlDirectory 'build-support.py'), $sourceManifest, (Join-Path $controlDirectory 'remote-driver.sh'))
        Invoke-LocalTool -File $scp -Arguments ($scpArguments + @('--') + $controls + @($MacHost + ':' + $remoteRoot + '/control/'))
        $remoteBuildNumber = if ($BuildNumber) { $BuildNumber } else { '' }
        $offlineArgument = if ($Offline) { 'true' } else { 'false' }
        # 引号中的参数均为已经严格限制的 staging path/正整数/布尔值，不执行用户自定义 shell 文本。
        $remoteCommand = "/bin/bash '$remoteRoot/control/remote-driver.sh' '$remoteRoot' '$remoteBuildNumber' '$offlineArgument'"
        Invoke-LocalTool -File $ssh -Arguments ($sshArguments + @('--', $MacHost, $remoteCommand))
        $artifacts = @('dashboard-trollstore.ipa', 'version.json', 'build-manifest.json', 'source-commit.txt', 'SHA256SUMS')
        foreach ($artifact in $artifacts) {
            Invoke-LocalTool -File $scp -Arguments ($scpArguments + @('--', ($MacHost + ':' + $remoteRoot + '/artifacts/' + $artifact), (Join-Path $returnedDirectory $artifact)))
        }
        # 不在收到的 ZIP/目录里运行解释器或构建工具；只用本地可信 helper -I 解析 ZIP/Mach-O/hash。
        Invoke-LocalTool -File $python -Arguments @('-I', $support, 'verify', '--ipa', (Join-Path $returnedDirectory 'dashboard-trollstore.ipa'), '--source-manifest', $sourceManifest)
        Invoke-LocalTool -File $python -Arguments @('-I', $support, 'output-check', '--root', $repoRoot, '--output', $OutputDirectory)
        if (-not (Test-Path -LiteralPath $OutputDirectory -PathType Container)) { [void](New-Item -ItemType Directory -Path $OutputDirectory) }
        foreach ($artifact in $artifacts) { [System.IO.File]::Copy((Join-Path $returnedDirectory $artifact), (Join-Path $OutputDirectory $artifact), $false) }
        Invoke-LocalTool -File $python -Arguments @('-I', $support, 'verify', '--ipa', (Join-Path $OutputDirectory 'dashboard-trollstore.ipa'), '--source-manifest', $sourceManifest)
        Write-Host ('Returned and verified ' + (Join-Path $OutputDirectory 'dashboard-trollstore.ipa'))
        Write-Host 'macOS performed cryptographic codesign verification; Windows rechecked ZIP, Mach-O/imports/signature structure, SHA-256 and approved source snapshot. No device installation was tested.'
        Write-Host 'This is an ad-hoc IPA, not a universal installer. Public App Group templates do not prove Apple provisioning approval or TrollStore compatibility; these remain unverified.'
        $exitCode = 0
    }
} catch {
    Write-Host ('BLOCKED: ' + $_.Exception.Message)
    $exitCode = 2
} finally {
    if ($remoteRoot -and $ssh -and $remoteRoot -match '^/private/tmp/zeeho-ios-remote\.[A-Za-z0-9]+$') {
        try {
            # 只清理本次 mktemp 目录，绝不改远程全局 SSH/工具配置或其他构建目录。
            Invoke-LocalTool -File $ssh -Arguments ($sshArguments + @('--', $MacHost, "rm -rf -- '$remoteRoot'"))
        } catch {
            Write-Host ('Remote cleanup was not completed; only this staging directory remains: ' + $remoteRoot)
        }
    }
    if ($localStage -and (Test-Path -LiteralPath $localStage)) { Remove-Item -LiteralPath $localStage -Recurse -Force }
}
exit $exitCode
