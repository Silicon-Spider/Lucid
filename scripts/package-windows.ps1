# Makes the Windows download: Lucid with its engines and everything else it needs inside,
# so that whoever downloads it has nothing to install and no terminal to open.
#
#   dist\Lucid-<version>-windows-x64.zip    unpack it and open Lucid
#
# The models are not inside: Lucid downloads them itself, from its window, the first time.
# Needs Swift, as scripts\setup.ps1 does.
param()

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Set-Location (Join-Path $PSScriptRoot '..')

function Invoke-Program([scriptblock]$Command, [string]$Failure) {
    $ErrorActionPreference = 'Continue'
    & $Command
    if ($LASTEXITCODE -ne 0) { throw $Failure }
}

$version = (Select-String -Path 'Sources\LucidApp\Desk.swift' -Pattern 'static let version = "(.*)"').Matches[0].Groups[1].Value
if (-not $version) { throw "Could not read Lucid's version from Sources\LucidApp\Desk.swift." }

Write-Host "build    Lucid $version"
Invoke-Program { swift build -c release --product Lucid } 'Lucid did not build.'
Invoke-Program { swift build -c release --product lucid-cli } 'lucid-cli did not build.'
$bin = swift build -c release --show-bin-path

$id = [guid]::NewGuid().ToString('N')
$stage = Join-Path ([System.IO.Path]::GetTempPath()) "lucid-package-$id"
$app = Join-Path $stage 'Lucid'
New-Item -ItemType Directory -Force -Path $app, (Join-Path $app 'LICENSES') | Out-Null
Copy-Item (Join-Path $bin 'Lucid.exe'), (Join-Path $bin 'lucid-cli.exe') $app

# Swift's own libraries, which a PC without Swift does not have. They are beside swiftCore.dll,
# wherever Swift was installed.
$core = (& where.exe swiftCore.dll 2>$null | Select-Object -First 1)
if (-not $core) { throw "Could not find Swift's libraries: swiftCore.dll is not on the PATH." }
$runtime = Split-Path $core
Copy-Item (Join-Path $runtime '*.dll') $app
Write-Host "copy     Swift's libraries from $runtime ($(@(Get-ChildItem $app -Filter *.dll).Count) files)"

# The engines, each in a folder of its own.
$engines = Join-Path $app 'engines'
& (Join-Path $PSScriptRoot 'setup.ps1') -EnginesInto $engines

# Microsoft's C++ libraries, which Swift's libraries and the engines are built on. Most PCs
# have them, because most programs bring them. A PC that does not would refuse to start
# Lucid, so they go beside every program here that needs them.
$system = Join-Path $env:SystemRoot 'System32'
$cpp = @('vcruntime140.dll', 'vcruntime140_1.dll', 'msvcp140.dll', 'msvcp140_1.dll', 'msvcp140_2.dll', 'vcomp140.dll') |
    ForEach-Object { Join-Path $system $_ } | Where-Object { Test-Path $_ }
$folders = @($app) + @(Get-ChildItem $engines -Recurse -Filter *.exe | ForEach-Object { $_.DirectoryName } | Sort-Object -Unique)
foreach ($folder in $folders) {
    foreach ($library in $cpp) {
        $there = Join-Path $folder (Split-Path $library -Leaf)
        if (-not (Test-Path $there)) { Copy-Item $library $there }
    }
}

Copy-Item 'LICENSE' (Join-Path $app 'LICENSES\Lucid.txt')
@'
Lucid comes with these, each under its own licence:

  whisper.cpp, the speech engine        MIT licence
                                        https://github.com/ggml-org/whisper.cpp
  llama.cpp, the cleanup engine         MIT licence
                                        https://github.com/ggml-org/llama.cpp
  The Swift runtime and Foundation      Apache licence 2.0, with the Runtime Library Exception
                                        https://www.swift.org/legal/license.html
  ICU, inside Foundation                Unicode licence
                                        https://www.unicode.org/license.txt
  Microsoft Visual C++ libraries        Microsoft's terms for redistributable code

The models Lucid downloads have licences of their own, shown where they are downloaded from.
'@ | Set-Content -Encoding UTF8 (Join-Path $app 'LICENSES\README.txt')
@'
Lucid: hold a key, speak, let go.

Open Lucid in this folder. Windows may say it protected your PC, because Lucid is not signed:
choose "More info", then "Run anyway". Lucid adds itself to the Start menu, so after the first
time you can open it from there. Keep this folder where it is, or open Lucid once more after
moving it.

Lucid sits beside the clock. Its window says what it still needs. The first time, that is its
models, which it downloads itself.
'@ | Set-Content -Encoding UTF8 (Join-Path $app 'README.txt')

# The engines must be found from inside the folder, wherever the folder is put.
# doctor also says the models are missing, which is as it should be, and is not a failure here.
$found = & { $ErrorActionPreference = 'Continue'; & (Join-Path $app 'lucid-cli.exe') doctor 2>&1 | Out-String }
$inside = @($found -split "`n" | Where-Object { $_ -match 'engine' -and $_ -match $id })
if ($inside.Count -lt 2) {
    Write-Host $found
    throw 'The packed Lucid does not find its own engines.'
}

New-Item -ItemType Directory -Force -Path 'dist' | Out-Null
$zip = Join-Path 'dist' "Lucid-$version-windows-x64.zip"
if (Test-Path $zip) { Remove-Item $zip }
Compress-Archive -Path $app -DestinationPath $zip
Remove-Item -Recurse -Force $stage
Write-Host "made     $zip ($([math]::Round((Get-Item $zip).Length / 1MB)) MB)"
