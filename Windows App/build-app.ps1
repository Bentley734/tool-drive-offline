param([string]$OutputDirectory, [string]$WebView2Package)
$ErrorActionPreference = 'Stop'
$arguments = @( (Join-Path $PSScriptRoot 'build-windows.py') )
if ($OutputDirectory) { $arguments += @('--output', [IO.Path]::GetFullPath($OutputDirectory)) }
if ($WebView2Package) { $arguments += @('--sdk', [IO.Path]::GetFullPath($WebView2Package)) }
$python = Get-Command python -ErrorAction SilentlyContinue
if ($python) { & $python.Source @arguments } else { & py -3 @arguments }
if ($LASTEXITCODE -ne 0) { throw 'The Windows app build did not complete.' }
