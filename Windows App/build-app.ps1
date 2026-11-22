param([string]$OutputDirectory)

$ErrorActionPreference = 'Stop'
$projectDir = $PSScriptRoot
$catalogPath = Join-Path (Split-Path -Parent $projectDir) 'catalog.json'
$outputDir = if ($OutputDirectory) { [System.IO.Path]::GetFullPath($OutputDirectory) } else { Join-Path $projectDir 'dist' }
$compilerPath = Join-Path $env:WINDIR 'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
if (-not (Test-Path -LiteralPath $compilerPath)) {
    $compilerPath = Join-Path $env:WINDIR 'Microsoft.NET/Framework/v4.0.30319/csc.exe'
}
if (-not (Test-Path -LiteralPath $compilerPath)) {
    throw 'The .NET Framework C# compiler was not found.'
}
New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
$executablePath = Join-Path $outputDir 'Tool Drive Offline.exe'
$compilerArgs = @(
    '/nologo', '/target:winexe', '/platform:anycpu', '/optimize+', '/warn:4', '/codepage:65001',
    ('/out:' + $executablePath),
    ('/win32manifest:' + (Join-Path $projectDir 'app.manifest')),
    ('/win32icon:' + (Join-Path $projectDir 'app.ico')),
    ('/resource:' + $catalogPath + ',ToolDriveOffline.catalog.json'),
    '/reference:System.dll', '/reference:System.Core.dll', '/reference:System.Drawing.dll',
    '/reference:System.Windows.Forms.dll', '/reference:System.Web.Extensions.dll', '/reference:System.Net.Http.dll',
    (Join-Path $projectDir 'AssemblyInfo.cs'),
    (Join-Path $projectDir 'ToolDriveOffline.cs'),
    (Join-Path $projectDir 'CatalogUpdates.cs'),
    (Join-Path $projectDir 'ColumnLayout.cs'),
    (Join-Path $projectDir 'AppUpdates.cs')
)
& $compilerPath @compilerArgs
if ($LASTEXITCODE -ne 0) { throw ('C# compilation failed: ' + $LASTEXITCODE) }
Copy-Item -LiteralPath (Join-Path $projectDir 'READ ME.txt') -Destination (Join-Path $outputDir 'READ ME.txt') -Force
Get-Item -LiteralPath $executablePath | Select-Object FullName, Length, LastWriteTime
