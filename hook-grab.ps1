# UserPromptSubmit hook for the dictation instance of Claude Code.
# Reads the submitted prompt from stdin JSON, writes the text as-is
# to dictate-out.txt (UTF-8, no BOM) and answers {"continue": false},
# so Claude Code stops right there and the prompt never reaches the model.
# Not exit code 2 (a blocked prompt): Claude Code 2.1.310 puts a blocked
# prompt back into its input, and the next Space would type a space there
# instead of starting a recording; after "continue": false the input stays
# empty. The prompt stays in the session's conversation instead, which is
# never sent to the model.
# The clipboard is NOT touched here; dictate-core.ahk handles pasting.

[Console]::InputEncoding = [Text.Encoding]::UTF8
[Console]::OutputEncoding = [Text.Encoding]::UTF8

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$logFile   = Join-Path $PSScriptRoot 'dictate.log'
$outFile   = Join-Path $PSScriptRoot 'dictate-out.txt'
$tmpFile   = Join-Path $PSScriptRoot 'dictate-out.tmp'

function Write-Log([string]$msg) {
    $line = "{0:yyyy-MM-dd HH:mm:ss} {1}`r`n" -f (Get-Date), $msg
    [IO.File]::AppendAllText($logFile, $line, $utf8NoBom)
}

$raw = [Console]::In.ReadToEnd()

try {
    $data = $raw | ConvertFrom-Json
} catch {
    Write-Log "bad json: $raw"
    [Console]::Error.WriteLine('[dictate] hook: could not parse stdin JSON')
    exit 2
}

$text = [string]$data.prompt

# Nothing gets through, slash commands included: Claude Code hands skills and
# custom commands (/deploy staging) to this hook before running them, so a
# pass-through for "/" would let them run in the dictation instance.

if ([string]::IsNullOrWhiteSpace($text)) {
    Write-Log 'empty prompt'
    [Console]::Error.WriteLine('[dictate] empty prompt, nothing written')
    exit 2
}

$text = $text.Trim()

# Atomic hand-off: write tmp, then rename, so AHK never reads a half-written file.
[IO.File]::WriteAllText($tmpFile, $text, $utf8NoBom)
if (Test-Path -LiteralPath $outFile) { Remove-Item -LiteralPath $outFile -Force }
Move-Item -LiteralPath $tmpFile -Destination $outFile -Force

Write-Log ("captured {0} chars: {1}" -f $text.Length, $text)
'{"continue": false, "stopReason": "[dictate] captured ' + $text.Length + ' chars"}'
exit 0
