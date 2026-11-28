# Sets Lucid up on Windows: installs the speech and cleanup engines, downloads the models,
# builds the app, and adds it to the Start menu.
# Safe to run again: what is already there is skipped, and model downloads continue.
#
#   scripts\setup.ps1                                the engines and Lucid's two models (about 1 GB)
#   scripts\setup.ps1 -WithGeneral                   also Qwen 3.5 4B (2.6 GB), for the Medium level
#   scripts\setup.ps1 -SpeechModel ggml-base.en.bin  a smaller, faster speech model instead
#   scripts\setup.ps1 -NoApp                         only what lucid-cli needs, without the app
#   scripts\setup.ps1 -EnginesInto folder            only the engines, into that folder
param(
    [switch]$WithGeneral,
    [string]$SpeechModel = 'ggml-large-v3-turbo-q5_0.bin',
    [switch]$NoApp,
    [string]$EnginesInto
)

$ErrorActionPreference = 'Stop'
# Downloads are many times slower while PowerShell draws its progress bar.
$ProgressPreference = 'SilentlyContinue'
Set-Location (Join-Path $PSScriptRoot '..')

# Runs a program. Older PowerShell treats anything a program writes to its error stream as a
# failure, and lucid-cli writes its progress there, so only the exit code decides.
function Invoke-Program([scriptblock]$Command, [string]$Failure) {
    $ErrorActionPreference = 'Continue'
    & $Command
    if ($LASTEXITCODE -ne 0) { throw $Failure }
}

if ($EnginesInto) {
    # For scripts\package-windows.ps1, which puts the engines inside the download.
    New-Item -ItemType Directory -Force -Path $EnginesInto | Out-Null
    $engines = (Resolve-Path $EnginesInto).Path
} else {
    if (-not (Get-Command swift -ErrorAction SilentlyContinue)) {
        throw 'Swift is required. Install it from https://www.swift.org/install/windows and run this again.'
    }

    Write-Host 'build    lucid-cli'
    Invoke-Program { swift build -c release --product lucid-cli } 'lucid-cli did not build.'
    $cli = Join-Path (swift build -c release --show-bin-path) 'lucid-cli.exe'

    $engines = & $cli folder engines
    $models = & $cli folder models
    if (-not $engines -or -not $models) { throw 'lucid-cli did not say where its folders are.' }
}

# Finds the download of an engine on GitHub that suits this PC: the zip whose name has every
# word in $Wanted and none in $Unwanted. Not every release comes with programs for Windows, so
# this looks back from the newest release until it finds one that does.
function Find-Download([string]$Repository, [string[]]$Wanted, [string[]]$Unwanted) {
    $headers = @{ 'User-Agent' = 'lucid-setup' }
    if ($env:GITHUB_TOKEN) { $headers['Authorization'] = "Bearer $env:GITHUB_TOKEN" }
    # Not wrapped in @(): that would make the whole list one item, and the loop would run once.
    $releases = Invoke-RestMethod "https://api.github.com/repos/$Repository/releases?per_page=30" -Headers $headers
    # Full releases first. llama.cpp marks every release a pre-release, so those come second.
    foreach ($early in @($false, $true)) {
        foreach ($release in $releases) {
            if ($release.draft -or ([bool]$release.prerelease -ne $early)) { continue }
            $fits = @($release.assets | Where-Object { $_.name -like '*.zip' } | Where-Object {
                $name = $_.name.ToLower()
                $missing = @($Wanted | Where-Object { $name -notlike "*$_*" })
                $present = @($Unwanted | Where-Object { $name -like "*$_*" })
                ($missing.Count -eq 0) -and ($present.Count -eq 0)
            } | Sort-Object { $_.name.Length })
            if ($fits.Count -gt 0) {
                Write-Host "found    $($fits[0].name) in $Repository $($release.tag_name)"
                return $fits[0]
            }
        }
    }
    Write-Host "None of the latest releases of $Repository has a download that suits this PC. They offer:"
    foreach ($release in ($releases | Select-Object -First 8)) {
        $names = @($release.assets | ForEach-Object { $_.name }) -join ', '
        Write-Host "  $($release.tag_name): $names"
    }
    throw "Could not choose a download of $Repository."
}

# Each engine gets a folder of its own. They cannot share one: both come with files of the same names.
function Install-Engine([string]$Program, [string]$Repository, [string[]]$Wanted, [string[]]$Unwanted) {
    $folder = Join-Path $engines ([System.IO.Path]::GetFileNameWithoutExtension($Program))
    if (Get-ChildItem -Path $folder -Filter $Program -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1) {
        Write-Host "have     $Program"
        return
    }
    $asset = Find-Download $Repository $Wanted $Unwanted
    Write-Host "download $($asset.name) ($([math]::Round($asset.size / 1MB)) MB)"
    $zip = Join-Path ([System.IO.Path]::GetTempPath()) $asset.name
    Invoke-WebRequest $asset.browser_download_url -OutFile $zip -Headers @{ 'User-Agent' = 'lucid-setup' }
    New-Item -ItemType Directory -Force -Path $folder | Out-Null
    Expand-Archive -Path $zip -DestinationPath $folder -Force
    Remove-Item $zip
    if (-not (Get-ChildItem -Path $folder -Filter $Program -Recurse | Select-Object -First 1)) {
        Write-Host "$($asset.name) has no $Program. Its programs are:"
        Get-ChildItem -Path $folder -Filter *.exe -Recurse | ForEach-Object { Write-Host "  $($_.Name)" }
        throw "$Program was not in the download."
    }
}

# The plain builds, which run on any PC's processor. The others need a particular graphics card.
Install-Engine 'whisper-server.exe' 'ggml-org/whisper.cpp' @('bin', 'x64') @('cublas', 'cuda', 'blas', 'vulkan', 'openvino', 'arm')
Install-Engine 'llama-server.exe' 'ggml-org/llama.cpp' @('bin', 'win', 'cpu', 'x64') @('arm')
if ($EnginesInto) { return }

function Get-Model([string]$Repository, [string]$File) {
    if (Test-Path (Join-Path $models $File)) {
        Write-Host "have     $File"
        return
    }
    Write-Host "download $File"
    Invoke-Program { & $cli download $Repository $File } "Could not download $File. Run this script again to continue it."
}

Get-Model 'ggerganov/whisper.cpp' $SpeechModel
Get-Model 'superwhisper/s1-mini-GGUF' 's1-mini-q4_k_m.gguf'
if ($WithGeneral) { Get-Model 'unsloth/Qwen3.5-4B-GGUF' 'Qwen3.5-4B-Q4_K_M.gguf' }

Write-Host ''
Invoke-Program { & $cli doctor --speech-model $SpeechModel } 'Setup did not finish. See what is missing above.'

if (-not $NoApp) {
    Write-Host ''
    Write-Host 'build    Lucid'
    Invoke-Program { swift build -c release --product Lucid } 'Lucid did not build.'
    $app = Join-Path (swift build -c release --show-bin-path) 'Lucid.exe'

    # A Start menu entry, so Lucid can be opened like any other app.
    $shortcut = Join-Path ([Environment]::GetFolderPath('Programs')) 'Lucid.lnk'
    $link = (New-Object -ComObject WScript.Shell).CreateShortcut($shortcut)
    $link.TargetPath = $app
    $link.WorkingDirectory = Split-Path $app
    $link.Description = 'Dictation that runs on this PC'
    $link.Save()

    Write-Host ''
    Write-Host 'Lucid is ready. Open it from the Start menu, or run:'
    Write-Host "  $app"
    Write-Host 'It sits beside the clock. Hold Right Ctrl and speak, then let go.'
}
