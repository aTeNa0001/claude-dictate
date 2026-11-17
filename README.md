# claude-dictate

English · [Русский](README.ru.md)

A classic voice-typing app for Windows, like the system-wide dictation hotkey in the
ChatGPT desktop app, but built on the speech recognition inside Claude Code. Claude Code
has `/voice` dictation, yet only for its own prompt: there is no global hotkey that types
into any window. This utility closes that gap. Press Ctrl+Space in any application,
speak, press again, and the text is pasted where the cursor was.

Under the hood Claude Code only acts as a "dictaphone": a hook intercepts the dictated
text, and the model never sees it. Transcription is free and does not count toward
subscription limits; the only model call is a short session title, once per start, on Haiku.

A small AutoHotkey utility, no build, no dependencies.

## This fork

A fork of [android6/claude-dictate](https://github.com/android6/claude-dictate). What is different:

- The recognition language defaults to Japanese (`"language": "ja"` in `dictate-settings.json`).
- A microphone level bar under the indicator while recording. Its track turns red after
  four seconds without any sound: the microphone is on, but nothing is heard.
- A live transcript: the end of what Claude Code has recognized so far is shown next to the
  indicator while you speak, so a long recording can be seen to be going in.
- Audio cues: the microphone came on, stopped by the hotkey, stopped by Claude Code itself
  (15 seconds of silence, the two-minute limit), nothing pasted.
- Every text is kept before it is pasted. Ctrl+Shift+Space pastes the last one again into the
  active window; `dictate-history.txt` holds all of them. A text that arrives after the script
  stopped waiting (`No text`) is kept the same way, shown as `↩ saved`.
- A one-command installer.

All of it is switched in `dictate.ini` (`repasteKey`, `preview`, `previewChars`, `sounds`,
`soundVolume`).

To install, in PowerShell:

```powershell
irm https://raw.githubusercontent.com/aTeNa0001/claude-dictate/master/install.ps1 | iex
```

It installs AutoHotkey v2 with winget if missing, clones this repository into
`~\tools\claude-dictate` (set `$env:CLAUDE_DICTATE_DIR` first for another place), creates
`dictate.ini` (with the path to `claude.exe` when Claude Code was installed through npm) and
starts the script. Running it again updates an existing install. Claude Code itself must
already be installed and signed in.

## Requirements

- Windows 10/11.
- [AutoHotkey v2](https://www.autohotkey.com/).
- [Claude Code](https://code.claude.com/) 2.1.295 or newer (tap-mode dictation, `onFailure`
  for hooks). The standard installer puts `claude.exe` in PATH, which is enough; otherwise set `claudeExe`
  in `dictate.ini`. Signed in with a claude.ai account on a Pro/Max/Team/Enterprise
  plan; dictation is not available with an API key.
- A microphone that desktop apps are allowed to use (Windows privacy settings).

## Getting started

1. Copy the folder anywhere.
2. Double-click `dictate-start.ahk`. On the first run a folder dialog asks which Claude
   profile to dictate with; the default `~\.claude` is preselected, so just press OK
   unless you have several accounts. Then a console with Claude Code opens, a small
   `○ ready` indicator appears in a screen corner, a green "H" icon in the tray.
3. The first time, Claude Code asks in that console whether to trust this folder:
   answer Yes. It will not ask again. Once you are comfortable, pick `Claude window:
   minimized` or `hidden` in the tray menu; the choice is remembered.

Exit: right-click the indicator or the tray icon, `Exit`. The Claude Code console
closes together with the script.

## Usage

| Key | Action |
|---|---|
| Ctrl+Space | start recording |
| Ctrl+Space again | stop and paste the text into the window you started in |
| Escape while recording | cancel, paste nothing |
| Ctrl+Shift+Space | paste the last dictated text again, into the active window |
| Ctrl+Alt+Space | history: the last 50 texts, newest first; Enter pastes the chosen one into the window you were in |
| Double-click the indicator | the same history; Enter copies to the clipboard |

Outside of a recording the script does not touch Escape. The clipboard is restored after pasting.

Claude Code stops a recording by itself after 15 seconds of silence and after two minutes;
in both cases the text is pasted automatically. A completely silent recording gives `No speech`.

The indicator can be dragged with the mouse; the position is remembered. Right-click on it
or on the tray icon opens the menu: profiles (check mark on the current one, click to switch),
console window mode (hidden, minimized, visible), `Autostart` (check mark = shortcut
`dictate-start.ahk.lnk` in `shell:startup`), `Reload`, `Exit`.

| Indicator | Meaning |
|---|---|
| `○ ready` | ready |
| `↻ updated` (yellow) | ready; Claude Code updated itself in the background, the old version keeps running until `Reload` |
| `… wait` (yellow) | the hotkey was pressed, the microphone is not on yet (0.2 to 1 second): do not speak yet |
| `● REC 1:53` | recording, countdown to two minutes, last 10 seconds in red |
| `… process` | recording stopped, waiting for the text |
| `✓ pasted` | pasted |
| `✕ ESC` | cancelled |
| `↩ saved` (yellow) | a text arrived too late to be pasted; it is kept, press Ctrl+Shift+Space |
| `No paste` / `No last` | the clipboard did not take the text (it is kept) / nothing to paste again |
| `No speech` / `No text` / `No mic` / `No Claude` | error, see `dictate.log` |

## Settings

Everything is in `dictate.ini`, every key has a comment: hotkeys (AutoHotkey notation,
e.g. `^Space`, `^!d`, `#v`), path to `claude.exe`, window mode, indicator position and
opacity, countdown limits, profiles. On first run the file is created
from `dictate.example.ini`. After editing, `Reload` from the menu.

Recognition language: `dictate-settings.json`, key `language` (`ja` in this fork, `ru` upstream; see the
[supported languages](https://code.claude.com/docs/en/voice-dictation)).

## Files

| File | Role |
|---|---|
| `dictate-start.ahk` | **run this one**: picks the profile and starts the core |
| `dictate-core.ahk` | the core: hotkey, Claude Code window, indicator, pasting. Does not run on its own |
| `dictate.ini` | settings; created from `dictate.example.ini`, not committed to git |
| `dictate-settings.json` | Claude Code settings for the dictation instance: language, tap mode, model, hook |
| `hook-grab.ps1` | the hook: intercepts the prompt, writes it to `dictate-out.txt`, stops Claude Code before the model |
| `dictate.log` | log: hook lines with the recognized text and `[ahk]` lines from the script |
| `dictate-history.txt` | every dictated text with its time; moved to `dictate-history.old.txt` at 2 MB. Not committed to git |
| `dictate-last.txt` | the last dictated text, for Ctrl+Shift+Space after a restart. Not committed to git |

## How the profile is chosen

A profile is a Claude Code config directory (`CLAUDE_CONFIG_DIR`) with its own login,
recognizable by a `.credentials.json` inside. `default` is Claude Code's own `~\.claude`.

**One account, the usual case.** Press OK on the preselected `~\.claude` in the first-run
dialog. The launcher starts the core with `default`, the core leaves `CLAUDE_CONFIG_DIR`
alone, Claude Code uses `~\.claude`. The menu shows `Profile: default`. Cancel in that
dialog means "do not start"; the question comes back next time.

**Several accounts.** Pick the profile folder in the first-run dialog. It becomes `last`
in `dictate.ini`, its parent folder becomes `dir`, and every sibling folder with a
`.credentials.json` shows up in the tray menu. With `dir` empty the parent is your user
folder, which covers the usual `~\.claude-work`, `~\.claude-personal` layout.

On every start the launcher takes the first that applies:

1. Command-line argument: a config directory or `default`. This is how the core restarts
   itself when you switch profiles from the menu or press `Reload`.
2. The `last` key: the profile used last time. Written automatically.
3. `default`.

## How it works

1. `dictate-core.ahk` runs `claude --settings dictate-settings.json` in a classic console
   (not Windows Terminal, which ignores keys posted to its window) and posts Space, Enter
   and Escape into it with `ControlSend`, without taking the focus.
2. `dictate-settings.json` enables tap-mode dictation and installs a `UserPromptSubmit` hook.
   The file is passed only to this instance; global Claude Code settings are untouched.
   If the hook fails to run, the prompt is blocked anyway (`"onFailure": "block"`), and
   `"disableAllHooks": false` keeps a profile from switching the hook off.
3. `hook-grab.ps1` receives the submitted prompt, writes it to `dictate-out.txt` and answers
   `{"continue": false}`: Claude Code stops right there, the model never sees the prompt.
   Not exit code 2 (a blocked prompt): Claude Code puts a blocked prompt back into its input,
   where it would turn the next Space into a typed space. The prompt stays in that
   instance's conversation instead, and after the first one Claude Code asks the model
   (Haiku, see point 8) for a session title once per start.
   Slash commands are captured too, so a skill typed into that console does not run; run
   `/login` and other commands in an ordinary Claude Code window with the same profile.
4. The script waits for the file, pastes the text via the clipboard and restores the old clipboard.
   A Space on a non-empty input types a space instead of starting a recording, so before
   every start the script reads Claude Code's input box from the console screen
   (`ReadConsoleOutputCharacter`). Normally it is empty. Text is left there only when the
   hook failed (the prompt is then blocked and put back) or keys were typed into the visible
   console; then the script erases it with Ctrl+U written straight into the console's
   input buffer (`WriteConsoleInput`; posted with `ControlSend` to a console without the
   focus, Ctrl+U arrives as a plain "u"), one per screen line, logs it, and waits until
   the screen shows the input empty.
5. The real microphone state is asked from the Windows audio system (Core Audio): while
   Claude Code records, its process has an active audio session on the microphone.
   Otherwise an empty recording cannot be told apart from a running one.
6. Claude Code's auto-update renames the running binary to `claude.exe.old.<n>` without
   a word. The script asks the running process for its path once a minute
   (`QueryFullProcessImageName`); when it stops matching the one seen at start, the
   indicator turns yellow.
7. `dictate-settings.json` pins the display mode (`"tui": "default"`), so the dictation
   instance looks the same in every profile and no startup offer to switch modes catches
   the keys.
8. It also sets the model to Haiku (`"model": "haiku"`): the dictation instance sends
   nothing to the model except the request for a session title, so the cheapest model
   is enough. Your other Claude Code windows keep their own model.
9. Windows slows down background processes to save power, and the dictation console is
   always in the background. The script turns this throttling off for Claude Code and its
   console (`SetProcessInformation`, `ProcessPowerThrottling`), so that a long pause does
   not slow down the start of a recording.

## Limitations

- Recognition quality is set by Anthropic's server and cannot be influenced. Russian mixed
  with English terms is recognized poorly. Claude Code has no custom vocabulary.
- Windows only. On macOS the hook scheme works the same, but AutoHotkey has to be replaced
  by Hammerspoon and posting keys to a window by tmux.
- At most two minutes per recording, a Claude Code limit.

## License

MIT. Not affiliated with or endorsed by Anthropic; Claude is a trademark of Anthropic, PBC.
