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
foreach ($checkName in @('FilterChecks', 'UpdateChecks', 'LayoutChecks', 'PerformanceChecks')) {
    $checkPath = Join-Path ([System.IO.Path]::GetTempPath()) ('ToolDriveOffline.' + $checkName + '.' + [guid]::NewGuid().ToString('N') + '.exe')
    try {
        $compilerArgs = @('/nologo', '/target:exe', '/codepage:65001', ('/out:' + $checkPath), '/reference:System.Core.dll', '/reference:System.Web.Extensions.dll', '/reference:System.Windows.Forms.dll', '/reference:System.Drawing.dll', (Join-Path $projectDir ($checkName + '.cs')))
        & $compilerPath @compilerArgs
        if ($LASTEXITCODE -ne 0) { throw ('Check compilation failed: ' + $LASTEXITCODE) }
        & $checkPath $ExecutablePath
        if ($LASTEXITCODE -ne 0) { throw ($checkName + ' failed: ' + $LASTEXITCODE) }
    }
    finally {
        if (Test-Path -LiteralPath $checkPath) { Remove-Item -LiteralPath $checkPath -Force }
    }
}
