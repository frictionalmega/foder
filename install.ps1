# Foder — Official Windows Installer (PowerShell)
# Repository: https://github.com/frictionalmega/foder
#
# One-line install:
#   irm https://foder.vercel.app/install.ps1 | iex
#
#Requires -Version 5.1
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ErrorActionPreference = "Stop"

$FODER_REPO    = "https://github.com/frictionalmega/foder"
$FODER_SITE    = "https://foder.vercel.app"
$FODER_VERSION = "0.1.0"

function Write-OK($m)   { Write-Host "  " -NoNewline; Write-Host "v" -ForegroundColor Green  -NoNewline; Write-Host "  $m" }
function Write-Warn($m) { Write-Host "  " -NoNewline; Write-Host "!" -ForegroundColor Yellow -NoNewline; Write-Host "  $m" }
function Write-Err($m)  { Write-Host "  " -NoNewline; Write-Host "x" -ForegroundColor Red    -NoNewline; Write-Host "  $m"; exit 1 }
function Write-Info($m) { Write-Host "  " -NoNewline; Write-Host "-" -ForegroundColor Cyan   -NoNewline; Write-Host "  $m" -ForegroundColor DarkGray }
function Write-Sep      { Write-Host "  ---------------------------------------------------------" -ForegroundColor DarkGray }

Write-Host ""
Write-Host "  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+" -ForegroundColor Cyan
Write-Host "  Foder - Local AI Coding Agent  v$FODER_VERSION" -ForegroundColor Cyan
Write-Host "  No cloud. No keys. Just code." -ForegroundColor DarkGray
Write-Host "  Source: $FODER_SITE" -ForegroundColor DarkGray
Write-Host "  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+" -ForegroundColor Cyan
Write-Host ""
Write-Sep
Write-Host ""

# ── Detect Python 3.10+ ───────────────────────────────────────────────────────
$Python = $null; $PyVersion = $null

foreach ($cmd in @("python3.13","python3.12","python3.11","python3.10","python3","python","py")) {
    if (Get-Command $cmd -ErrorAction SilentlyContinue) {
        try {
            $ver = & $cmd -c "import sys;print('.'.join(map(str,sys.version_info[:2])))" 2>$null
            if ($ver) {
                $p = $ver.Trim().Split('.')
                if ([int]$p[0] -ge 3 -and [int]$p[1] -ge 10) {
                    $Python = $cmd; $PyVersion = $ver.Trim(); break
                }
            }
        } catch {}
    }
}

if (-not $Python) {
    Write-Err "Python 3.10+ not found.`n`n  Download: https://python.org/downloads/`n  Tick 'Add Python to PATH' during install."
}
Write-OK "Python $PyVersion"

try { & $Python -m pip --version 2>$null | Out-Null; Write-OK "pip available" }
catch { Write-Err "pip not found. Reinstall Python with pip included." }

function Ask-YesNo($prompt, $default = $true) {
    # Returns $true / $false. Non-interactive sessions (CI, `irm | iex` without a
    # console) fall back to the default instead of blocking forever.
    try {
        if ([Environment]::UserInteractive -eq $false) {
            Write-Warn "Non-interactive session - assuming '$(if ($default) { 'Y' } else { 'N' })' for: $prompt"
            return $default
        }
    } catch {}
    try {
        $r = Read-Host $prompt
    } catch {
        return $default
    }
    if ([string]::IsNullOrWhiteSpace($r)) { return $default }
    return ($r -match "^[Yy]")
}

# ── Check Ollama ──────────────────────────────────────────────────────────────
if (Get-Command ollama -ErrorAction SilentlyContinue) {
    try {
        $ov = (& ollama --version 2>$null) -join "" | Select-String "\d" | ForEach-Object { $_.Line }
        Write-OK "Ollama: $ov"
    } catch { Write-OK "Ollama: found" }
} else {
    Write-Warn "Ollama not found."
    Write-Host "  Foder requires Ollama to run local LLMs." -ForegroundColor DarkGray
    Write-Host "  Download: https://ollama.com" -ForegroundColor Yellow
    if (-not (Ask-YesNo "  Continue without Ollama? [y/N]" $false)) {
        Write-Host "  Install Ollama first, then re-run the installer."
        exit 1
    }
}

# ── Get foder source ──────────────────────────────────────────────────────────
# Official sources:
#   installer:  https://foder.vercel.app/install.ps1
#   repository: https://github.com/frictionalmega/foder
$installDir = $PWD.Path

if (-not (Test-Path (Join-Path $installDir "pyproject.toml"))) {
    $installDir = "$env:USERPROFILE\.foder_src"

    # Safety: only ever write inside the user's profile.
    if (-not $installDir.StartsWith($env:USERPROFILE, [StringComparison]::OrdinalIgnoreCase)) {
        Write-Err "Refusing to use install path '$installDir' (outside the user profile)."
    }

    if (Test-Path "$installDir\.git") {
        Write-Info "Updating existing installation..."
        try {
            $branch = (& git -C "$installDir" rev-parse --abbrev-ref HEAD 2>$null | Select-Object -First 1)
            if (-not $branch -or $branch -eq "HEAD") { $branch = "main" }
            & git -C "$installDir" pull --rebase origin $branch 2>$null
            if ($LASTEXITCODE -ne 0) { & git -C "$installDir" pull origin $branch 2>$null }
            if ($LASTEXITCODE -ne 0) {
                Write-Info "Could not update - continuing with the version already on disk"
            }
        } catch {
            Write-Info "Could not update - continuing with the version already on disk"
        }
    } else {
        # Only clear a leftover directory if it looks like foder's own source tree.
        if ((Test-Path $installDir) -and -not (Test-Path (Join-Path $installDir "pyproject.toml"))) {
            Write-Warn "'$installDir' exists and is not a foder checkout - leaving it alone"
            $installDir = "$env:USERPROFILE\.foder_src"
        } elseif (Test-Path $installDir) {
            Write-Info "Refreshing incomplete checkout at $installDir"
            Remove-Item -Recurse -Force $installDir
        }

        $cloned = $false
        if (Get-Command git -ErrorAction SilentlyContinue) {
            Write-Info "Fetching foder from GitHub..."
            try {
                & git clone --depth=1 "$FODER_REPO" "$installDir"
                $cloned = ($LASTEXITCODE -eq 0)
            } catch { $cloned = $false }
        }

        if (-not $cloned) {
            # Fallback: source ZIP archive from GitHub (Expand-Archive only supports .zip,
            # NOT .tar.gz — use the zip endpoint instead).
            Write-Warn "git clone unavailable - falling back to the GitHub source archive"
            $zipUrl = "$FODER_REPO/archive/refs/heads/main.zip"
            $tmp = Join-Path $env:TEMP "foder_src_$([Guid]::NewGuid().ToString('N'))"
            New-Item -ItemType Directory -Force -Path $tmp | Out-Null
            try {
                [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
                Invoke-WebRequest -Uri $zipUrl -OutFile (Join-Path $tmp "foder.zip") -UseBasicParsing
                if (Test-Path $installDir) { Remove-Item -Recurse -Force $installDir }
                Expand-Archive -Path (Join-Path $tmp "foder.zip") -DestinationPath $tmp -Force
                $extracted = Get-ChildItem -Path $tmp -Directory | Select-Object -First 1
                if (-not $extracted -or -not (Test-Path (Join-Path $extracted.FullName "pyproject.toml"))) {
                    throw "Downloaded archive does not contain a foder source tree."
                }
                New-Item -ItemType Directory -Force -Path $installDir | Out-Null
                Copy-Item -Recurse -Force (Join-Path $extracted.FullName "*") $installDir
                Write-OK "Source archive downloaded and unpacked"
                Write-Warn "Installed from a snapshot - run 'foder --update' once git is available"
            } catch {
                Write-Err "Could not download foder from $zipUrl.`n  Install Git for Windows and retry: https://git-scm.com"
            } finally {
                Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
            }
        }
    }
}

Set-Location $installDir

# ── Install ───────────────────────────────────────────────────────────────────
Write-Host ""
Write-Info "Installing foder..."

$installed = $false
foreach ($flags in @("-q", "--user -q", "--user", "--break-system-packages -q")) {
    try {
        & $Python -m pip install -e . $flags.Split(' ') 2>$null
        if ($LASTEXITCODE -eq 0) { $installed = $true; break }
    } catch {}
}

if (-not $installed) {
    Write-Err "pip install failed.`n  Try manually: cd $installDir; pip install -e ."
}

# ── Create ~/.foder directory structure ───────────────────────────────────────
# Only creates missing directories. An existing profile directory is never
# touched, so memories, preferences, sessions and history survive reinstalls.
$foderDir = "$env:USERPROFILE\.foder"
if ((Test-Path $foderDir) -and -not (Test-Path $foderDir -PathType Container)) {
    Write-Err "'$foderDir' exists but is not a directory. Move or remove it and retry."
}
New-Item -ItemType Directory -Force -Path "$foderDir\skills"   | Out-Null
New-Item -ItemType Directory -Force -Path "$foderDir\sessions" | Out-Null
Write-OK "~\.foder\ directory ready"

# ── Verify + PATH ─────────────────────────────────────────────────────────────
Write-Host ""
if (Get-Command foder -ErrorAction SilentlyContinue) {
    $foderPath = (Get-Command foder).Source
    Write-OK "foder installed: $foderPath"
} else {
    $found = $false
    $scriptDirs = @(
        "$env:APPDATA\Python\Scripts",
        "$env:LOCALAPPDATA\Programs\Python\Python313\Scripts",
        "$env:LOCALAPPDATA\Programs\Python\Python312\Scripts",
        "$env:LOCALAPPDATA\Programs\Python\Python311\Scripts",
        "$env:LOCALAPPDATA\Programs\Python\Python310\Scripts",
        "$env:USERPROFILE\AppData\Roaming\Python\Scripts"
    )
    foreach ($dir in $scriptDirs) {
        if (Test-Path "$dir\foder.exe") {
            Write-OK "foder installed to: $dir"
            Write-Warn "Add to PATH. Run in PowerShell (Admin):"
            Write-Host "  [Environment]::SetEnvironmentVariable('PATH', [Environment]::GetEnvironmentVariable('PATH','User')+';$dir', 'User')" -ForegroundColor Cyan
            $found = $true; break
        }
    }
    if (-not $found) {
        Write-Warn "foder installed. Restart your terminal and run 'foder'."
    }
}

# ── Optional starter model ────────────────────────────────────────────────────
if (Get-Command ollama -ErrorAction SilentlyContinue) {
    try {
        $models = & ollama list 2>$null
        if ($models -notmatch "qwen2.5-coder") {
            Write-Host ""
            Write-Host "  Recommended starter model: qwen2.5-coder:3b (~2GB)" -ForegroundColor DarkGray
            if (Ask-YesNo "  Pull it now? [Y/n]" $true) {
                Write-Info "Pulling qwen2.5-coder:3b..."
                & ollama pull qwen2.5-coder:3b
                Write-OK "Model ready — this is your default coding model"
            } else {
                Write-Info "Skipped. Pull one later with:  ollama pull qwen2.5-coder:3b"
            }
        } else { Write-OK "qwen2.5-coder already available" }
    } catch { Write-Warn "Could not check ollama models — run: ollama pull qwen2.5-coder:3b" }
}

# ── Done ──────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Sep
Write-Host ""
Write-Host "  Installation complete!" -ForegroundColor Green
Write-Host ""
Write-Host "  Start:     foder" -ForegroundColor Cyan
Write-Host "  Help:      foder --help" -ForegroundColor Cyan
Write-Host "  Update:    foder --update" -ForegroundColor Cyan
Write-Host "  Uninstall: foder --uninstall" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Before starting, make sure Ollama is running: ollama serve" -ForegroundColor DarkGray
Write-Host "  Website: $FODER_SITE" -ForegroundColor DarkGray
Write-Host "  GitHub:  $FODER_REPO" -ForegroundColor DarkGray
Write-Host ""
