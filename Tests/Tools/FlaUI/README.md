# Vendored FlaUI Binaries

This directory contains vendored UI Automation libraries used by the Windows
GUI test harness (`Tests\Harness\SP.UiTest.psm1`). They are committed to the
repo so the test loop is reproducible and does not require internet access or
`dotnet`/`nuget.exe` on the test machine.

## Contents

| File                              | Version    | Target     | Source |
|-----------------------------------|------------|------------|--------|
| `FlaUI.Core.dll`                  | 4.0.0      | net48      | https://www.nuget.org/packages/FlaUI.Core/4.0.0 |
| `FlaUI.UIA3.dll`                  | 4.0.0      | net48      | https://www.nuget.org/packages/FlaUI.UIA3/4.0.0 |
| `Interop.UIAutomationClient.dll`  | 10.19041.0 | net45      | https://www.nuget.org/packages/Interop.UIAutomationClient/10.19041.0 |
| `LICENSE.txt`                     | -          | -          | FlaUI MIT license (applies to both FlaUI DLLs) |

## Why FlaUI 4.0 and not the latest

FlaUI 5.x targets `.NET 6+`, which is not loadable from Windows PowerShell 5.1
(which runs on .NET Framework 4.x). FlaUI 4.0 is the last version with a
`net48` build, which is the target PS 5.1 can load via `Add-Type -Path`.

## How to refresh

If a future PS 7-only test environment becomes the standard, replace these
with the latest `net6.0-windows` builds. To refresh the existing net48 set:

```powershell
$packages = @(
    @{ Name = "FlaUI.Core"; Version = "4.0.0" },
    @{ Name = "FlaUI.UIA3"; Version = "4.0.0" },
    @{ Name = "Interop.UIAutomationClient"; Version = "10.19041.0" }
)
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Add-Type -AssemblyName System.IO.Compression.FileSystem
foreach ($p in $packages) {
    $url = "https://www.nuget.org/api/v2/package/$($p.Name)/$($p.Version)"
    $nupkg = Join-Path $env:TEMP "$($p.Name).$($p.Version).nupkg"
    $dir   = Join-Path $env:TEMP "$($p.Name).$($p.Version)"
    Invoke-WebRequest -Uri $url -OutFile $nupkg -UseBasicParsing
    if (Test-Path $dir) { Remove-Item $dir -Recurse -Force }
    [System.IO.Compression.ZipFile]::ExtractToDirectory($nupkg, $dir)
}
Copy-Item "$env:TEMP\FlaUI.Core.4.0.0\lib\net48\FlaUI.Core.dll"                          .\FlaUI.Core.dll
Copy-Item "$env:TEMP\FlaUI.UIA3.4.0.0\lib\net48\FlaUI.UIA3.dll"                          .\FlaUI.UIA3.dll
Copy-Item "$env:TEMP\Interop.UIAutomationClient.10.19041.0\lib\net45\Interop.UIAutomationClient.dll" .\Interop.UIAutomationClient.dll
```

## License

FlaUI is MIT-licensed (see `LICENSE.txt`).
Interop.UIAutomationClient is also MIT-licensed (https://github.com/microsoft/CsWinRT).
