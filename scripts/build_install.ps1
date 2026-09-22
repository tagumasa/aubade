# Build and install the Odin aubade binary to %LOCALAPPDATA%\Programs\aubade
# (override with AUBADE_INSTALL_DIR).  The install directory is added to the
# user-level PATH if missing.  Run from an "x64 Native Tools Command
# Prompt for VS" — MSVC links the C artifacts.  The C artifacts under
# lib\ must already exist — 'just build' produces them.
$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent $ScriptDir

if (-not (Get-Command odin -ErrorAction SilentlyContinue)) {
    Write-Error "the Odin compiler is not on PATH - install the tracked nightly first"
    exit 1
}

$ArchName = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "arm64" } else { "amd64" }
$LibDir = Join-Path $Root "lib\windows_$ArchName"

if (-not (Test-Path (Join-Path $LibDir "libtree-sitter.lib")) -or
    -not (Test-Path (Join-Path $LibDir "grammars"))) {
    Write-Error "C artifacts missing under $LibDir - run 'just build' first (from a VS developer prompt)"
    exit 1
}

Write-Host "Building aubade from $Root ..." -ForegroundColor Cyan
Set-Location $Root

odin build src -collection:src=src "-collection:grammars=$LibDir\grammars" -out:aubade.exe

if ($LASTEXITCODE -ne 0) {
    Write-Error "Build failed with exit code $LASTEXITCODE"
    exit $LASTEXITCODE
}

$InstallDir = if ($env:AUBADE_INSTALL_DIR) {
    $env:AUBADE_INSTALL_DIR
} else {
    Join-Path $env:LOCALAPPDATA "Programs\aubade"
}

if (-not (Test-Path $InstallDir)) {
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
}

Copy-Item -Path aubade.exe -Destination (Join-Path $InstallDir "aubade.exe") -Force

$Installed = Join-Path $InstallDir "aubade.exe"
Write-Host "Installed: $Installed" -ForegroundColor Green
& $Installed --version

# Ensure the install directory is on the user-level PATH.
$UserPath = [Environment]::GetEnvironmentVariable("PATH", "User")
if (-not $UserPath -or $UserPath -notlike "*$InstallDir*") {
    $NewPath = if ($UserPath) { "$InstallDir;$UserPath" } else { $InstallDir }
    [Environment]::SetEnvironmentVariable("PATH", $NewPath, "User")
    $env:PATH = "$InstallDir;$env:PATH"
    Write-Host "Added $InstallDir to user PATH." -ForegroundColor Green
}

# Client registrations point at the absolute path of the binary that runs
# `aubade setup`, so a location change never breaks them - but another
# aubade earlier on PATH shadows this one in shells.
$OnPath = Get-Command aubade -ErrorAction SilentlyContinue
if ($OnPath -and $OnPath.Source -ne $Installed) {
    Write-Host ""
    Write-Host "note: another aubade resolves earlier on PATH: $($OnPath.Source)" -ForegroundColor Yellow
    Write-Host "      (remove it if it is not wanted), then"
    Write-Host "      register your preferred client(s):"
} else {
    Write-Host ""
    Write-Host "First run:  aubade init  - initialise global configuration"
    Write-Host "Then register your preferred client(s):"
}
Write-Host "  aubade setup claudecode  - auto-configure Claude Code"
Write-Host "  aubade setup codex       - auto-configure Codex CLI"
Write-Host "  aubade setup opencode    - auto-configure OpenCode"
Write-Host "  aubade setup zcode       - auto-configure ZCode"
