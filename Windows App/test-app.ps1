param([string]$ExecutablePath)

$ErrorActionPreference = 'Stop'
$projectDir = $PSScriptRoot
if (-not $ExecutablePath) { $ExecutablePath = Join-Path $projectDir 'dist/Tool Drive Offline.exe' }
$ExecutablePath = (Resolve-Path -LiteralPath $ExecutablePath).Path
$compilerPath = Join-Path $env:WINDIR 'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
if (-not (Test-Path -LiteralPath $compilerPath)) {
    $compilerPath = Join-Path $env:WINDIR 'Microsoft.NET/Framework/v4.0.30319/csc.exe'
}
if (-not (Test-Path -LiteralPath $compilerPath)) { throw 'The .NET Framework C# compiler was not found.' }

$testDir = Join-Path ([IO.Path]::GetTempPath()) ('ToolDriveOffline.Tests.' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testDir | Out-Null
$previousProfile = $env:TOOL_DRIVE_DATA_DIR
$references = @('System', 'System.Core', 'System.Drawing', 'System.Net.Http', 'System.Web.Extensions',
    'System.Windows.Forms', 'Microsoft.CSharp', 'System.Security', 'System.IO.Compression', 'System.IO.Compression.FileSystem',
    'System.Xml', 'System.Xml.Linq', 'Microsoft.VisualBasic')

function Build-Check([string]$Name, [string[]]$Sources) {
    $checkPath = Join-Path $testDir ($Name + '.exe')
    $compilerArgs = @('/nologo', '/target:exe', '/codepage:65001', ('/out:' + $checkPath))
    $compilerArgs += @($references | ForEach-Object { '/reference:' + $_ + '.dll' })
    $compilerArgs += $Sources
    & $compilerPath @compilerArgs | Out-Host
    if ($LASTEXITCODE -ne 0) { throw ($Name + ' compilation failed: ' + $LASTEXITCODE) }
    return $checkPath
}

try {
    $env:TOOL_DRIVE_DATA_DIR = Join-Path $testDir 'legacy-profile'
    foreach ($checkName in @('FilterChecks', 'UpdateChecks', 'LayoutChecks', 'PerformanceChecks', 'AppUpdateChecks', 'ScrollBarChecks', 'ThemeChecks')) {
        $checkPath = Build-Check $checkName @((Join-Path $projectDir ($checkName + '.cs')))
        & $checkPath $ExecutablePath
        if ($LASTEXITCODE -ne 0) { throw ($checkName + ' failed: ' + $LASTEXITCODE) }
    }

    # The media service fixture injects local HTTP responses and owns its profile.
    $mediaSources = @((Join-Path $projectDir 'tests/MediaChecks.cs'))
    $mediaSources += @(Get-ChildItem -LiteralPath $projectDir -Filter 'WindowsMedia*.cs' | ForEach-Object { $_.FullName })
    $codec = Join-Path $projectDir 'WindowsLosslessAudio.cs'
    if (Test-Path -LiteralPath $codec) { $mediaSources += $codec }
    $media = Build-Check 'MediaChecks' $mediaSources
    & $media
    if ($LASTEXITCODE -ne 0) { throw ('MediaChecks failed: ' + $LASTEXITCODE) }

    $env:TOOL_DRIVE_DATA_DIR = Join-Path $testDir 'native-profile'
    $smoke = Build-Check 'WebViewSmokeChecks' @((Join-Path $projectDir 'tests/WebViewSmokeChecks.cs'))
    foreach ($phase in @('first','reopen')) {
        & $smoke $ExecutablePath (Join-Path $projectDir 'tests/webview-smoke.js') $phase
        if ($LASTEXITCODE -ne 0) { throw ('Native WebView2 smoke failed (' + $phase + '): ' + $LASTEXITCODE) }
    }
}
finally {
    $env:TOOL_DRIVE_DATA_DIR = $previousProfile
    # Edge renderer processes can release their user data files shortly after
    # the managed host exits. Only this run's GUID-named folder is removed.
    for ($attempt = 0; $attempt -lt 20 -and (Test-Path -LiteralPath $testDir); $attempt++) {
        Remove-Item -LiteralPath $testDir -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $testDir) { Start-Sleep -Milliseconds 200 }
    }
}
