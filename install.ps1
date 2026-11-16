# claude-dictate one-command installer (Windows PowerShell 5.1 and PowerShell 7).
#
#   irm https://raw.githubusercontent.com/aTeNa0001/claude-dictate/master/install.ps1 | iex
#
# What it does:
#   1. installs AutoHotkey v2 with winget if it is missing
#   2. clones (or updates) this repository into ~\tools\claude-dictate
#      (override with $env:CLAUDE_DICTATE_DIR; falls back to a zip download without git)
#   3. creates dictate.ini on the first install, with the path to claude.exe when
#      Claude Code was installed through npm and claude.exe is not in PATH
#   4. starts dictate-start.ahk
#
# Claude Code itself must already be installed and signed in with a claude.ai account.
# Keep this file ASCII-only: it is run through "irm | iex".

$ErrorActionPreference = 'Stop'

$Repo   = 'aTeNa0001/claude-dictate'
$Branch = 'master'
$Dir    = if ($env:CLAUDE_DICTATE_DIR) { $env:CLAUDE_DICTATE_DIR } else { Join-Path $env:USERPROFILE 'tools\claude-dictate' }

function Say([string]$msg) { Write-Host "[claude-dictate] $msg" }

function Find-AutoHotkey {
    $candidates = @(
        (Join-Path $env:ProgramFiles 'AutoHotkey\v2\AutoHotkey64.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\AutoHotkey\v2\AutoHotkey64.exe'),
        (Join-Path $env:ProgramFiles 'AutoHotkey\v2\AutoHotkey32.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\AutoHotkey\v2\AutoHotkey32.exe')
    )
    foreach ($path in $candidates) {
        if (Test-Path -LiteralPath $path) { return $path }
    }
    return $null
}

# claude.exe: PATH, the native installer location, then next to an npm "claude" shim.
function Find-ClaudeExe {
    $cmd = Get-Command claude.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return @{ Path = $cmd.Source; InPath = $true } }
    $native = Join-Path $env:USERPROFILE '.local\bin\claude.exe'
    if (Test-Path -LiteralPath $native) { return @{ Path = $native; InPath = $true } }   # dictate-core.ahk checks this one itself
    foreach ($shim in @(Get-Command claude -All -ErrorAction SilentlyContinue)) {
        if (-not $shim.Source) { continue }
        $exe = Join-Path (Split-Path -Parent $shim.Source) 'node_modules\@anthropic-ai\claude-code\bin\claude.exe'
        if (Test-Path -LiteralPath $exe) { return @{ Path = $exe; InPath = $false } }
    }
    return $null
}

# ---- 1. AutoHotkey v2 ------------------------------------------------
$ahk = Find-AutoHotkey
if (-not $ahk) {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        throw 'AutoHotkey v2 is not installed and winget is not available. Install it from https://www.autohotkey.com/ and run this again.'
    }
    Say 'installing AutoHotkey v2 with winget...'
    winget install -e --id AutoHotkey.AutoHotkey --accept-source-agreements --accept-package-agreements
    $ahk = Find-AutoHotkey
    if (-not $ahk) { throw 'AutoHotkey v2 was not found after the winget install.' }
}
Say "AutoHotkey: $ahk"

# ---- 2. the files ----------------------------------------------------
if (Test-Path -LiteralPath (Join-Path $Dir '.git')) {
    Say "updating $Dir"
    git -C $Dir pull --ff-only
    if ($LASTEXITCODE -ne 0) { Say 'git pull failed (local changes?), keeping the files as they are' }
} elseif (Test-Path -LiteralPath (Join-Path $Dir 'dictate-start.ahk')) {
    Say "already installed in $Dir (not a git clone), keeping the files as they are"
} else {
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Dir) | Out-Null
    if (Get-Command git -ErrorAction SilentlyContinue) {
        Say "cloning into $Dir"
        git clone "https://github.com/$Repo.git" $Dir
        if ($LASTEXITCODE -ne 0) { throw 'git clone failed.' }
    } else {
        Say "downloading into $Dir (git not found)"
        $tmp = Join-Path ([IO.Path]::GetTempPath()) ("claude-dictate-" + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tmp | Out-Null
        try {
            $zip = Join-Path $tmp 'src.zip'
            Invoke-WebRequest -UseBasicParsing -Uri "https://github.com/$Repo/archive/refs/heads/$Branch.zip" -OutFile $zip
            Expand-Archive -LiteralPath $zip -DestinationPath $tmp
            $src = Get-ChildItem -LiteralPath $tmp -Directory | Select-Object -First 1
            Move-Item -LiteralPath $src.FullName -Destination $Dir
        } finally {
            Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# ---- 3. dictate.ini --------------------------------------------------
$claude = Find-ClaudeExe
if (-not $claude) {
    Say 'WARNING: Claude Code (claude.exe) was not found. Install it, or set claudeExe in dictate.ini.'
}
$ini = Join-Path $Dir 'dictate.ini'
if (Test-Path -LiteralPath $ini) {
    Say 'dictate.ini already exists, left untouched'
} else {
    $text = Get-Content -LiteralPath (Join-Path $Dir 'dictate.example.ini') -Raw
    if ($claude -and -not $claude.InPath) {
        $line = 'claudeExe=' + $claude.Path
        $text = [regex]::Replace($text, '(?m)^claudeExe=[ \t]*\r?$', { param($m) $line }, 1)
        Say "claude.exe is not in PATH, wrote its path to dictate.ini: $($claude.Path)"
    }
    # UTF-16 LE with BOM: the encoding AutoHotkey's IniRead handles for non-ASCII paths.
    [IO.File]::WriteAllText($ini, $text, [Text.Encoding]::Unicode)
    Say 'created dictate.ini (default profile ~\.claude; switch profiles from the tray menu)'
}

# ---- 4. start --------------------------------------------------------
Start-Process -FilePath $ahk -ArgumentList ('"' + (Join-Path $Dir 'dictate-start.ahk') + '"') -WorkingDirectory $Dir
Say 'started. Ctrl+Space: record, Ctrl+Space again: paste, Escape: cancel.'
Say 'First run: answer Yes in the Claude Code console if it asks to trust the folder.'
Say 'Tray icon menu: hide the console, Autostart, Reload, Exit.'
