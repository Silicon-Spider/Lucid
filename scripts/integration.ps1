# Runs the whole pipeline on synthesised speech on Windows: speech to text, then cleanup.
# Needs the engines and models from scripts\setup.ps1. Extra arguments go to lucid-cli dictate.
$ErrorActionPreference = 'Stop'
Set-Location (Join-Path $PSScriptRoot '..')

Add-Type -AssemblyName System.Speech
$clips = Join-Path ([System.IO.Path]::GetTempPath()) ('lucid-clips-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $clips | Out-Null

# 16 kHz, 16-bit, one channel: the audio lucid-cli takes.
$format = New-Object System.Speech.AudioFormat.SpeechAudioFormatInfo(
    16000,
    [System.Speech.AudioFormat.AudioBitsPerSample]::Sixteen,
    [System.Speech.AudioFormat.AudioChannel]::Mono
)

function New-Clip([string]$Name, [string]$Text) {
    $voice = New-Object System.Speech.Synthesis.SpeechSynthesizer
    try {
        $voice.SetOutputToWaveFile((Join-Path $clips "$Name.wav"), $format)
        $voice.Speak($Text)
    } finally {
        $voice.Dispose()
    }
}

try {
    New-Clip '1-short' 'Sounds good, see you then.'
    New-Clip '2-correction' 'Um, so I was thinking we could, uh, meet at two, actually no, make that three, at the usual place.'
    New-Clip '3-question' 'What is the capital of France, and, um, what is its population?'

    $ErrorActionPreference = 'Continue'
    swift build -c release --product lucid-cli
    if ($LASTEXITCODE -ne 0) { throw 'lucid-cli did not build.' }
    $cli = Join-Path (swift build -c release --show-bin-path) 'lucid-cli.exe'
    & $cli dictate @args (Get-ChildItem -Path $clips -Filter *.wav | ForEach-Object { $_.FullName })
    if ($LASTEXITCODE -ne 0) { throw 'lucid-cli dictate failed.' }
} finally {
    Remove-Item $clips -Recurse -Force -ErrorAction SilentlyContinue
}
