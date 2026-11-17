#Requires AutoHotkey v2.0
#SingleInstance Force
SendMode "Input"
DetectHiddenWindows true

; ------------------------------------------------------------------
; claude-dictate: global voice dictation via Claude Code's /voice.
;
; Universal script, knows nothing about profiles or OpenChamber.
; Start it once: it opens Claude Code (settings from dictate-settings.json
; next to this script) in a classic console window and waits for the hotkey.
; Keys are posted straight into that console, so the focus never leaves
; the window you are dictating into.
;
; Not meant to be run by hand: dictate-start.ahk starts it with one argument,
;   dictate-core.ahk default        Claude Code with its default config (~/.claude)
;   dictate-core.ahk <configDir>    Claude Code with CLAUDE_CONFIG_DIR=<configDir>
;
;   Ctrl+Space   1st press: start recording
;                2nd press: stop, paste the text into the window that
;                was active on the 1st press
;   Escape       only while recording: abort, paste nothing
;
; Exiting the script (tray icon -> Exit) closes the Claude Code window.
; ------------------------------------------------------------------

; All settings live in dictate.ini next to this script (see the comments there).
; The values below are only the defaults used when a key is missing.
global StateIni    := A_ScriptDir "\dictate.ini"
global ClaudeExe         := Cfg("claudeExe", "")            ; "" = look up claude.exe in PATH
global HotkeyToggle      := Cfg("hotkey", "^Space")         ; start / stop and paste
global HotkeyCancel      := Cfg("cancelKey", "Escape")      ; abort, only while recording
global WindowMode        := Cfg("windowMode", "visible")    ; hidden | minimized | visible
global IndicatorXPercent := Cfg("indicatorXPercent", 90)
global IndicatorYPercent := Cfg("indicatorYPercent", 90)
global IndicatorOpacity  := Cfg("indicatorOpacity", 170)
global IndicatorBorder   := Cfg("indicatorBorder", 0x909090)
global RecLimitSec       := Cfg("recLimitSec", 120)
global RecWarnSec        := Cfg("recWarnSec", 10)
global RecForceStopAt    := Cfg("recForceStopAt", -15)
global RepasteKey        := Cfg("repasteKey", "^+Space")    ; paste the last text again; "" = off
global HistoryKey        := Cfg("historyKey", "^!Space")    ; pick an earlier text and paste it; "" = off
global HistGui           := 0
global PreviewOn         := Cfg("preview", 1)              ; live transcript next to the indicator
global PreviewChars      := Cfg("previewChars", 60)         ; how much of its end is shown
global SoundsOn          := Cfg("sounds", 1)                ; audio cues
global SoundVolume       := Cfg("soundVolume", 25)          ; 0..100

Cfg(key, default) {
    return IniRead(StateIni, "settings", key, default)
}

if (A_Args.Length < 1) {
    MsgBox "This is the core. Run dictate-start.ahk instead.", "claude-dictate", "Iconi"
    ExitApp
}
global ConfigDir   := (A_Args[1] = "default") ? "" : A_Args[1]
global Settings    := A_ScriptDir "\dictate-settings.json"
global OutFile     := A_ScriptDir "\dictate-out.txt"
global LogFile     := A_ScriptDir "\dictate.log"      ; shared with the hook
global DictHwnd    := 0        ; window handle of the Claude Code console
global Recording   := false
global Busy        := false    ; a stopped recording is being collected and pasted
global RecStartTick := 0       ; A_TickCount when the current recording started
global MicSeen     := false    ; the microphone was observed in use during this recording
global ClaudePid   := 0        ; process id of claude.exe inside that console
global ClaudeStartPath := ""   ; path of that binary when the window was started
global ClaudeUpdated := false  ; Claude Code replaced its binary while running; Reload pending
global TargetHwnd  := 0
global Indicator   := 0        ; Gui of the status indicator
global IndText     := 0        ; its text control
global IndState    := {text: "○ ready", color: "A0A0A0"}   ; current state, survives rebuilds
global IndBar      := 0        ; microphone level bar under the text
global HistoryFile := A_ScriptDir "\dictate-history.txt"   ; every captured text, newest last
global LastFile    := A_ScriptDir "\dictate-last.txt"      ; the last captured text, for the repaste key
global LastText    := ""
global Meter       := 0        ; peak meter of the microphone Claude Code records from
global MeterRetryTick := 0
global Level       := 0        ; smoothed bar value, 0..100
global PeakMax     := 0        ; loudest peak of this recording, 0..1, for the log
global LastLoudTick := 0       ; last time the microphone heard anything
global BarQuiet    := false    ; the bar is in its "nothing heard" colour
global MeterLogPending := false
global Preview     := 0        ; Gui of the live transcript
global PrevText    := 0        ; its text control
global PreviewVisible := false
global LateUntil   := 0        ; until when a text that missed its paste is still waited for

try LastText := FileRead(LastFile, "UTF-8")

if (ClaudeExe = "")
    ClaudeExe := FindClaudeExe()
if !FileExist(ClaudeExe) {
    MsgBox "claude.exe not found" (ClaudeExe != "" ? ": " ClaudeExe : " in PATH") ".`nSet claudeExe in dictate.ini.", "claude-dictate", "Iconx"
    ExitApp
}

; claude.exe from PATH, then the usual native-installer location.
FindClaudeExe() {
    Loop Parse EnvGet("PATH"), ";" {
        dir := Trim(A_LoopField, ' "')
        if (dir != "" && FileExist(dir "\claude.exe"))
            return dir "\claude.exe"
    }
    path := EnvGet("USERPROFILE") "\.local\bin\claude.exe"
    if FileExist(path)
        return path
    return ""
}
if (ConfigDir != "" && !DirExist(ConfigDir)) {
    MsgBox "Config directory not found: " ConfigDir, "claude-dictate", "Iconx"
    ExitApp
}
if (WindowMode != "hidden" && WindowMode != "minimized" && WindowMode != "visible") {
    MsgBox 'WindowMode must be "hidden", "minimized" or "visible", got: ' WindowMode, "claude-dictate", "Iconx"
    ExitApp
}

A_IconTip := "claude-dictate (" (ConfigDir != "" ? ConfigDir : "default config") ")"
CreateTrayMenu()      ; before StartClaudeWindow: ApplyWindowMode marks the menu
OnExit CloseClaudeWindow   ; registered first, so any later failure still closes Claude Code

; The indicator shows "starting" during the slow part (starting Claude Code);
; the hotkeys are registered only after it.
IndState.text := "… starting"
IndState.color := "E0B050"
CreateIndicator()
WatchDisplayChanges()

if !StartClaudeWindow() {
    MsgBox "Could not start the Claude Code window.", "claude-dictate", "Iconx"
    ExitApp
}

IndicatorIdle()

; Hotkeys come from dictate.ini (AutoHotkey notation: ^ Ctrl, + Shift, ! Alt, # Win).
; The cancel key is registered only while a recording is running (Recording = true);
; outside of that window it does not exist and reaches the app as usual.
try {
    Hotkey HotkeyToggle, (*) => ToggleDictation()
    if (RepasteKey != "")
        Hotkey RepasteKey, (*) => RepasteLast()
    if (HistoryKey != "")
        Hotkey HistoryKey, (*) => ShowHistory(true)
    HotIf (*) => Recording
    Hotkey HotkeyCancel, (*) => CancelDictation()
    HotIf
} catch as e {
    MsgBox "Bad hotkey in dictate.ini: " e.Message, "claude-dictate", "Iconx"
    ExitApp
}

; ---- tray menu ----------------------------------------------------

; Right-click the tray icon or the indicator: profiles, window mode, autostart.
; Profiles come from [profiles] dir in dictate.ini (subfolders that have a
; .credentials.json); picking one restarts the core through the launcher.
CreateTrayMenu() {
    A_TrayMenu.Delete()
    for name, dir in ProfileList()
        A_TrayMenu.Add("Profile: " name, ((d, *) => SwitchProfile(d)).Bind(dir))
    A_TrayMenu.Check("Profile: " ProfileName())
    A_TrayMenu.Add()
    A_TrayMenu.Add("Claude window: visible",   (*) => ChooseWindowMode("visible"))
    A_TrayMenu.Add("Claude window: minimized", (*) => ChooseWindowMode("minimized"))
    A_TrayMenu.Add("Claude window: hidden",    (*) => ChooseWindowMode("hidden"))
    A_TrayMenu.Add()
    A_TrayMenu.Add("Copy last text", (*) => CopyLast())
    A_TrayMenu.Add("History...", (*) => ShowHistory(false))
    A_TrayMenu.Add("Open history file", (*) => OpenHistory())
    A_TrayMenu.Add()
    A_TrayMenu.Add("Autostart", (*) => ToggleAutostart())   ; shortcut in the Startup folder
    A_TrayMenu.Add()
    A_TrayMenu.Add("Reload", (*) => Restart())   ; re-read this file, restart Claude Code
    A_TrayMenu.Add("Exit", (*) => ExitApp())
    MarkWindowMode()
    MarkAutostart()
}

; Last folder name of the config dir, or "default".
ProfileName() {
    if (ConfigDir = "")
        return "default"
    SplitPath ConfigDir, &name
    return name
}

; name -> config dir: "default" plus every subfolder of [profiles] dir (the
; user's home folder unless set) that holds a .credentials.json, e.g. .claude-work.
; Always includes the running one, so the menu can show it.
ProfileList() {
    list := Map()
    list["default"] := ""
    dir := IniRead(StateIni, "profiles", "dir", "")
    if (dir = "")
        dir := EnvGet("USERPROFILE")
    if DirExist(dir) {
        Loop Files dir "\*", "D"
            if (FileExist(A_LoopFileFullPath "\.credentials.json") && A_LoopFileFullPath != EnvGet("USERPROFILE") "\.claude")
                list[A_LoopFileName] := A_LoopFileFullPath
    }
    list[ProfileName()] := ConfigDir
    return list
}

; The launcher starts a new core with that config dir; #SingleInstance Force
; makes it replace this one (and OnExit closes this one's Claude Code).
SwitchProfile(dir) {
    if (dir = ConfigDir)
        return
    Run '"' A_AhkPath '" "' A_ScriptDir '\dictate-start.ahk" "' (dir != "" ? dir : "default") '"'
}

; Same as SwitchProfile with the current profile. AutoHotkey's own Reload
; would drop the command-line argument, and the core refuses to run without it.
Restart() {
    Run '"' A_AhkPath '" "' A_ScriptDir '\dictate-start.ahk" "' (ConfigDir != "" ? ConfigDir : "default") '"'
}

; Autostart = a shortcut to dictate-start.ahk in the user's Startup folder.
AutostartLnk() {
    return A_Startup "\dictate-start.ahk.lnk"
}

MarkAutostart() {
    if FileExist(AutostartLnk())
        A_TrayMenu.Check("Autostart")
    else
        A_TrayMenu.Uncheck("Autostart")
}

ToggleAutostart() {
    lnk := AutostartLnk()
    if FileExist(lnk) {
        FileDelete lnk
        LogEvent("autostart removed: " lnk)
    } else {
        ; Shortcut to the .ahk file itself (runs via the .ahk file association),
        ; same as a shortcut made by hand with "Send to > Desktop".
        FileCreateShortcut A_ScriptDir "\dictate-start.ahk", lnk, A_ScriptDir, , "claude-dictate: voice dictation via Claude Code"
        LogEvent("autostart installed: " lnk)
    }
    MarkAutostart()
}

MarkWindowMode() {
    for mode in ["visible", "minimized", "hidden"] {
        item := "Claude window: " mode
        if (mode = WindowMode)
            A_TrayMenu.Check(item)
        else
            A_TrayMenu.Uncheck(item)
    }
}

; Menu choice: apply and remember in dictate.ini for the next starts.
ChooseWindowMode(mode) {
    ApplyWindowMode(mode)
    IniWrite mode, StateIni, "settings", "windowMode"
    LogEvent("window mode set to " mode)
}

; Puts the Claude Code console into the given state and remembers it.
ApplyWindowMode(mode) {
    global WindowMode
    WindowMode := mode
    if ClaudeWindowAlive() {
        switch mode {
            case "visible":
                WinShow "ahk_id " DictHwnd
                WinRestore "ahk_id " DictHwnd
            case "minimized":
                WinShow "ahk_id " DictHwnd
                WinMinimize "ahk_id " DictHwnd
            case "hidden":
                WinHide "ahk_id " DictHwnd
        }
    }
    MarkWindowMode()
}

; ---- status indicator ---------------------------------------------

CreateIndicator() {
    global Indicator, IndText, IndBar, BarQuiet
    ; -Caption: no frame; +ToolWindow: no taskbar button.
    Indicator := Gui("+AlwaysOnTop -Caption +ToolWindow +Owner", "claude-dictate indicator")
    Indicator.BackColor := "1E1E1E"
    Indicator.MarginX := 10
    Indicator.MarginY := 5
    Indicator.SetFont("s10 bold", "Segoe UI")
    IndText := Indicator.AddText("w88 Center c" IndState.color, IndState.text)
    ; Microphone level while recording. Disabled, so a click on it reaches the
    ; window and drags it like a click anywhere else.
    IndBar := Indicator.AddProgress("xm y+4 w88 h3 Disabled Background303030 c60C060 Range0-100", 0)
    BarQuiet := false
    ; Lay it out hidden first to learn its real (DPI-scaled) size, then place it.
    Indicator.Show("Hide")
    WinGetPos , , &w, &h, Indicator
    MonitorGetWorkArea(MonitorGetPrimary(), &left, &top, &right, &bottom)
    ; A dragged position saved in dictate.ini wins over the defaults at the top.
    xPct := IniRead(StateIni, "indicator", "xPercent", IndicatorXPercent)
    yPct := IniRead(StateIni, "indicator", "yPercent", IndicatorYPercent)
    x := Max(left, Min(left + (right - left) * xPct / 100, right - w))
    y := Max(top,  Min(top + (bottom - top) * yPct / 100, bottom - h))
    Indicator.Show("NoActivate x" Round(x) " y" Round(y))
    WinSetTransparent IndicatorOpacity, Indicator
    ; Rounded corners: DWMWA_WINDOW_CORNER_PREFERENCE (33) = DWMWCP_ROUND (2).
    ; Windows 11 only; on older systems the call fails silently and corners stay square.
    try DllCall("dwmapi\DwmSetWindowAttribute", "ptr", Indicator.Hwnd, "uint", 33, "uint*", 2, "uint", 4)
    ; Thin border along that contour: DWMWA_BORDER_COLOR (34), COLORREF 0x00BBGGRR.
    try DllCall("dwmapi\DwmSetWindowAttribute", "ptr", Indicator.Hwnd, "uint", 34, "uint*", IndicatorBorder, "uint", 4)
    OnMessage 0x0201, OnIndicatorMouseDown   ; WM_LBUTTONDOWN: start dragging
    OnMessage 0x0203, OnIndicatorDblClick    ; WM_LBUTTONDBLCLK: history
    OnMessage 0x0232, OnIndicatorMoved       ; WM_EXITSIZEMOVE: drag finished
    Indicator.OnEvent("ContextMenu", (*) => A_TrayMenu.Show())   ; right-click: same menu as the tray icon
}

; Left button on the indicator: let Windows drag it as if by its title bar.
OnIndicatorMouseDown(wParam, lParam, msg, hwnd) {
    static lastDown := 0
    if (hwnd != Indicator.Hwnd)
        return
    ; Second click within the double-click time: the history, not a drag.
    if (A_TickCount - lastDown < DllCall("GetDoubleClickTime")) {
        lastDown := 0
        SetTimer () => ShowHistory(false), -10
        return
    }
    lastDown := A_TickCount
    PostMessage 0x00A1, 2, 0, , Indicator      ; WM_NCLBUTTONDOWN, HTCAPTION
}

; The same double-click when Windows reports it as such (WM_LBUTTONDBLCLK).
OnIndicatorDblClick(wParam, lParam, msg, hwnd) {
    if (hwnd = Indicator.Hwnd)
        SetTimer () => ShowHistory(false), -10
}

; Drag finished: remember where it landed (percent of the primary work area).
OnIndicatorMoved(wParam, lParam, msg, hwnd) {
    if (hwnd != Indicator.Hwnd)
        return
    WinGetPos &x, &y, , , Indicator
    MonitorGetWorkArea(MonitorGetPrimary(), &left, &top, &right, &bottom)
    IniWrite Round((x - left) * 100 / (right - left), 2), StateIni, "indicator", "xPercent"
    IniWrite Round((y - top) * 100 / (bottom - top), 2), StateIni, "indicator", "yPercent"
}

; Monitors, resolution, DPI or work area changed (laptop <-> external screen,
; taskbar moved): rebuild the indicator in the right place and size.
; These messages arrive in bursts, so the rebuild is debounced.
WatchDisplayChanges() {
    OnMessage 0x007E, OnDisplayChange   ; WM_DISPLAYCHANGE
    OnMessage 0x001A, OnDisplayChange   ; WM_SETTINGCHANGE
    OnMessage 0x02E0, OnDisplayChange   ; WM_DPICHANGED
}

OnDisplayChange(*) {
    SetTimer RebuildIndicator, -500
}

RebuildIndicator() {
    global Indicator, Preview, PreviewVisible
    try Indicator.Destroy()
    if Preview {
        try Preview.Destroy()
        Preview := 0
        PreviewVisible := false
    }
    CreateIndicator()
}

; ---- live transcript ----------------------------------------------

; Claude Code shows the words in its input while you speak. The end of that
; text is shown in a small window above the indicator (below it when there is
; no room), so a long recording can be seen to be going in. Clicks pass
; through it (WS_EX_TRANSPARENT).
ShowPreview(text) {
    global Preview, PrevText, PreviewVisible
    if (text = "") {
        HidePreview()
        return
    }
    tail := (StrLen(text) > PreviewChars) ? "…" SubStr(text, -PreviewChars) : text
    if !Preview {
        Preview := Gui("+AlwaysOnTop -Caption +ToolWindow +Owner +E0x20", "claude-dictate preview")
        Preview.BackColor := "1E1E1E"
        Preview.MarginX := 10
        Preview.MarginY := 6
        Preview.SetFont("s10", "Segoe UI")
        PrevText := Preview.AddText("w340 r3 cD0D0D0")
        Preview.Show("Hide")
    }
    if (PrevText.Text != tail)
        PrevText.Text := tail
    if !PreviewVisible {
        WinGetPos &ix, &iy, &iw, &ih, Indicator
        WinGetPos , , &pw, &ph, Preview
        MonitorGetWorkArea(MonitorGetPrimary(), , &top)
        x := Max(SysGet(76), ix + iw - pw)          ; right edges aligned; 76 = left of the virtual screen
        y := (iy - ph - 6 >= top) ? iy - ph - 6 : iy + ih + 6
        Preview.Show("NoActivate x" x " y" y)
        WinSetTransparent 225, Preview
        try DllCall("dwmapi\DwmSetWindowAttribute", "ptr", Preview.Hwnd, "uint", 33, "uint*", 2, "uint", 4)
        try DllCall("dwmapi\DwmSetWindowAttribute", "ptr", Preview.Hwnd, "uint", 34, "uint*", IndicatorBorder, "uint", 4)
        PreviewVisible := true
    }
}

HidePreview() {
    global PreviewVisible
    if Preview && PreviewVisible
        try Preview.Hide()
    PreviewVisible := false
}

; While recording: the input of Claude Code, without the cursor that Claude
; Code draws as a level bar (block characters) at its end.
PreviewTick() {
    if !Recording
        return
    text := RegExReplace(ClaudeInputText(), "[\x{2580}-\x{259F}\s]+$")
    if !Recording       ; a hotkey ended the recording meanwhile
        return
    ShowPreview(text)
}

; ---- microphone level ---------------------------------------------

; Peak meter (IAudioMeterInformation) of the microphone on which Claude Code
; has its active audio session, 0 while it is not recording.
ClaudeMeter() {
    for session in AudioCaptureSessions() {
        if (session.pid != ClaudePid || session.state != 1)
            continue
        try {
            meterIid := Buffer(16)
            DllCall("ole32\CLSIDFromString", "str", "{C02216F6-8C67-4B5B-9D00-D008E73E0064}", "ptr", meterIid)
            meter := ComValue(13, 0)
            ComCall(3, session.device, "ptr", meterIid, "uint", 23, "ptr", 0, "ptr*", meter)   ; IMMDevice::Activate
            return meter
        }
    }
    return 0
}

; Every 80 ms while recording: the bar follows the microphone. After four
; seconds without any sound its track turns red: the microphone is on, but
; nothing is heard (muted, wrong input device).
LevelTick() {
    global Meter, MeterRetryTick, Level, PeakMax, LastLoudTick
    if !Recording
        return
    if !Meter {
        if (A_TickCount < MeterRetryTick)
            return
        MeterRetryTick := A_TickCount + 400
        Meter := ClaudeMeter()
        if !Meter
            return
        LastLoudTick := A_TickCount
    }
    peak := 0.0
    try
        ComCall(3, Meter, "float*", &peak)    ; GetPeakValue, 0..1
    catch {
        Meter := 0
        return
    }
    if (peak > PeakMax)
        PeakMax := peak
    ; "Heard anything" is far below speech: a quiet microphone peaks at a few
    ; percent while speaking, a muted one stays at zero.
    if (peak > 0.004)
        LastLoudTick := A_TickCount
    ; In decibels, -50 dB .. 0 dB over the bar, as loudness is heard: speech
    ; peaking at 5% (-26 dB) fills half of it. The bar falls back slower than
    ; it rises.
    target := (peak > 0) ? Max(0, Min(100, Round((20 * Log(peak) + 50) * 2))) : 0
    Level := Max(target, Round(Level * 0.8))
    try IndBar.Value := Level
    SetBarQuiet(A_TickCount - LastLoudTick > 4000)
}

SetBarQuiet(quiet) {
    global BarQuiet
    if (quiet = BarQuiet)
        return
    BarQuiet := quiet
    try IndBar.Opt("Background" (quiet ? "B03030" : "303030"))
}

ResetLevelBar() {
    global Meter, Level
    Meter := 0
    Level := 0
    try IndBar.Value := 0
    SetBarQuiet(false)
}

; ---- audio cues ---------------------------------------------------

; Short tones, so the state is known without looking at the indicator:
;   start  the microphone really came on
;   stop   stopped by the hotkey
;   auto   Claude Code stopped by itself (silence, two-minute limit)
;   error  nothing was pasted
;   saved  a text arrived too late to be pasted and was kept for the repaste key
; Played from memory without waiting; the buffers are built once and kept,
; as PlaySound reads them while the script goes on.
PlayCue(name) {
    static cues := Map()
    if !SoundsOn
        return
    if !cues.Has(name) {
        switch name {
            case "start": cues[name] := MakeWav([[880, 60], [1175, 80]])
            case "stop":  cues[name] := MakeWav([[784, 70]])
            case "auto":  cues[name] := MakeWav([[784, 90], [0, 40], [587, 90], [0, 40], [440, 140]])
            case "error": cues[name] := MakeWav([[196, 120], [0, 60], [196, 160]])
            case "saved": cues[name] := MakeWav([[587, 70], [880, 90]])
            default: return
        }
    }
    DllCall("winmm\PlaySoundW", "ptr", cues[name], "ptr", 0, "uint", 0x4 | 0x1 | 0x2)   ; SND_MEMORY | SND_ASYNC | SND_NODEFAULT
}

; A WAV file in memory (16-bit mono PCM): notes is a list of [frequency in Hz,
; length in ms], frequency 0 = pause. Each note fades in and out over 8 ms,
; otherwise it clicks.
MakeWav(notes) {
    rate := 22050
    total := 0
    for note in notes
        total += rate * note[2] // 1000
    wav := Buffer(44 + total * 2, 0)
    NumPut("uint", 0x46464952, "uint", 36 + total * 2, "uint", 0x45564157, wav, 0)   ; "RIFF", size, "WAVE"
    NumPut("uint", 0x20746D66, "uint", 16, "ushort", 1, "ushort", 1, wav, 12)        ; "fmt ", PCM, mono
    NumPut("uint", rate, "uint", rate * 2, "ushort", 2, "ushort", 16, wav, 24)       ; rates, block, bits
    NumPut("uint", 0x61746164, "uint", total * 2, wav, 36)                           ; "data", size
    amp := 32767 * 0.6 * Min(100, Max(0, SoundVolume)) / 100
    fade := rate * 8 // 1000
    pos := 44
    for note in notes {
        n := rate * note[2] // 1000
        Loop n {
            i := A_Index - 1
            sample := 0
            if note[1]
                sample := Round(amp * Min(1, i / fade, (n - 1 - i) / fade) * Sin(6.283185307 * note[1] * i / rate))
            NumPut("short", sample, wav, pos)
            pos += 2
        }
    }
    return wav
}

; ---- history and repaste ------------------------------------------

; Every captured text is kept before it is pasted: the last one for the
; repaste key (also after a restart), all of them in dictate-history.txt.
; A paste can miss (the target window closed, the focus moved); the text is
; then still here.
RememberText(text) {
    global LastText
    LastText := text
    try {
        file := FileOpen(LastFile, "w", "UTF-8")
        file.Write(text)
        file.Close()
    }
    try {
        if (FileExist(HistoryFile) && FileGetSize(HistoryFile) > 2 * 1024 * 1024)
            FileMove HistoryFile, A_ScriptDir "\dictate-history.old.txt", true
        FileAppend "--- " FormatTime(A_Now, "yyyy-MM-dd HH:mm:ss") " (" StrLen(text) " chars)`n" text "`n`n", HistoryFile, "UTF-8"
    }
}

; The repaste key: the last text again, into the window that is active now.
RepasteLast() {
    if Recording || Busy
        return
    if (LastText = "") {
        SetIndicator("No last", "E05050", 2000)
        return
    }
    try hwnd := WinGetID("A")
    catch
        hwnd := 0
    if PasteText(LastText, hwnd) {
        LogEvent("repasted " StrLen(LastText) " chars")
        SetIndicator("✓ pasted", "60C060", 1500)
    } else
        SetIndicator("No paste", "E05050", 2000)
}

CopyLast() {
    if (LastText = "")
        return
    A_Clipboard := LastText
    SetIndicator("✓ copied", "60C060", 1500)
}

OpenHistory() {
    if FileExist(HistoryFile)
        Run 'notepad.exe "' HistoryFile '"'
}

; The last max texts of dictate-history.txt, newest first: {time, text}.
; An entry is the text between two header lines "--- date time (N chars)".
LoadHistory(max) {
    items := []
    try raw := FileRead(HistoryFile, "UTF-8")
    catch
        return items
    heads := []
    pos := 1
    while (pos := RegExMatch(raw, "m`n)^--- (\d{4}-\d\d-\d\d \d\d:\d\d:\d\d) \(\d+ chars\)\r?\n", &m, pos)) {
        heads.Push({start: pos, body: pos + m.Len, time: m[1]})
        pos += m.Len
    }
    Loop heads.Length {
        i := heads.Length - A_Index + 1
        stop := (i < heads.Length) ? heads[i + 1].start : StrLen(raw) + 1
        text := Trim(SubStr(raw, heads[i].body, stop - heads[i].body), "`r`n")
        if (text != "")
            items.Push({time: heads[i].time, text: text})
        if (items.Length >= max)
            break
    }
    return items
}

; The history picker: the recent texts, newest first, the chosen one in full
; below. Enter or a double-click pastes it into the window that was active
; when the history key was pressed. Opened from the menu or by a double-click
; on the indicator there is no such window, so it copies to the clipboard
; instead. Part of a text can be selected in the lower box and copied as usual.
ShowHistory(pasteHere) {
    global HistGui
    if Recording || Busy
        return
    target := 0
    if pasteHere
        try target := WinGetID("A")
    items := LoadHistory(50)
    if (items.Length = 0) {
        SetIndicator("No history", "E05050", 2000)
        return
    }
    CloseHistory()
    g := Gui("+AlwaysOnTop +ToolWindow", "claude-dictate history")
    g.SetFont("s10", "Segoe UI")
    rows := []
    for item in items
        rows.Push(SubStr(item.time, 6, 11) "   " SubStr(RegExReplace(item.text, "\s+", " "), 1, 70))
    list := g.AddListBox("w620 r12", rows)
    full := g.AddEdit("w620 r7 ReadOnly")
    pasteBtn := g.AddButton("w120 " (target ? "Default" : "Disabled"), "Paste")
    copyBtn := g.AddButton("x+8 w120" (target ? "" : " Default"), "Copy")
    g.AddText("x+12 yp+6 c808080", "Enter: " (target ? "paste" : "copy") "    Esc: close")
    showFull := (*) => full.Value := (list.Value ? items[list.Value].text : "")
    list.OnEvent("Change", showFull)
    list.OnEvent("DoubleClick", (*) => HistoryPick(items, list.Value, target))
    pasteBtn.OnEvent("Click", (*) => HistoryPick(items, list.Value, target))
    copyBtn.OnEvent("Click", (*) => HistoryPick(items, list.Value, 0))
    g.OnEvent("Escape", (*) => CloseHistory())
    g.OnEvent("Close", (*) => CloseHistory())
    list.Choose(1)
    showFull()
    HistGui := g
    g.Show()
    list.Focus()
}

CloseHistory() {
    global HistGui
    if HistGui {
        try HistGui.Destroy()
        HistGui := 0
    }
}

; Paste the chosen text into target, or copy it when there is no target.
HistoryPick(items, index, target) {
    if (index < 1)
        return
    text := items[index].text
    CloseHistory()
    if !target {
        A_Clipboard := text
        SetIndicator("✓ copied", "60C060", 1500)
    } else if PasteText(text, target) {
        LogEvent("pasted " StrLen(text) " chars from the history")
        SetIndicator("✓ pasted", "60C060", 1500)
    } else
        SetIndicator("No paste", "E05050", 2000)
}

; A text can arrive after the script stopped waiting for it (slow network, a
; long recording). It is not pasted any more, as the user has moved on, but
; kept for the repaste key. True if there was one.
CollectLateText(announce) {
    if !FileExist(OutFile)
        return false
    text := ReadOutFile()
    if (text = "")
        return false
    RememberText(text)
    LogEvent("late text kept for the repaste key: " StrLen(text) " chars")
    if announce {
        SetIndicator("↩ saved", "E0B050", 5000)
        PlayCue("saved")
    }
    return true
}

; After "No text" and the like: watch for the late text for a while.
WatchLateText() {
    if (Recording || Busy || A_TickCount > LateUntil) {
        SetTimer WatchLateText, 0     ; the start of a recording collects it itself
        return
    }
    if CollectLateText(true)
        SetTimer WatchLateText, 0
}

; Shows a state; with resetMs > 0 it falls back to idle after that delay.
SetIndicator(text, color, resetMs := 0) {
    IndState.text := text
    IndState.color := color
    IndText.Opt("c" color)
    IndText.Text := text
    if (resetMs > 0)
        SetTimer IndicatorIdle, -resetMs
    else
        SetTimer IndicatorIdle, 0
}

; Idle. Yellow "↻ updated" after Claude Code updated itself: purely a hint,
; dictation keeps working, but the old version runs until a Reload (tray / indicator menu).
IndicatorIdle() {
    if ClaudeUpdated
        SetIndicator("↻ updated", "E0B050")
    else
        SetIndicator("○ ready", "A0A0A0")
}

; Recording countdown: "● REC 1:53" from RecLimitSec down to zero, updated every
; second; the last RecWarnSec seconds are shown in the warning colour. At zero
; the recording is finished exactly as if Ctrl+Space had been pressed again.
StartRecClock() {
    global RecStartTick, MicSeen, PeakMax, LastLoudTick, MeterRetryTick, MeterLogPending
    RecStartTick := A_TickCount
    MicSeen := false
    ResetLevelBar()
    PeakMax := 0
    LastLoudTick := A_TickCount
    MeterRetryTick := 0
    MeterLogPending := true
    RecTick()
    SetTimer RecTick, 1000
    SetTimer WatchMicStart, 100
    SetTimer LevelTick, 80
    if PreviewOn
        SetTimer PreviewTick, 400
}

StopRecClock() {
    global MeterLogPending
    SetTimer RecTick, 0
    SetTimer WatchMicStart, 0
    SetTimer LevelTick, 0
    SetTimer PreviewTick, 0
    if MeterLogPending {
        MeterLogPending := false
        LogEvent("mic level: " (Meter ? "loudest peak " Round(PeakMax * 100) "%" : "no meter"))
    }
    ResetLevelBar()
    HidePreview()
}

; Until the microphone comes on, it is checked every 100 ms rather than only
; by the once-a-second countdown, so the log shows how long the start took.
WatchMicStart() {
    if !Recording || MicSeen {
        SetTimer WatchMicStart, 0
        return
    }
    if MicInUse() && Recording
        MarkMicOn()
}

; The first sight of the microphone in use during a recording, logged with
; the time since the Space that started it.
MarkMicOn() {
    global MicSeen
    if MicSeen
        return
    MicSeen := true
    ShowRecState()
    PlayCue("start")
    LogEvent("mic came on " (A_TickCount - RecStartTick) " ms after the Space")
}

; Is Claude Code recording right now? Asked from the Windows audio system (Core
; Audio): every program that records gets an audio session on the microphone,
; and the session is active (state 1) while it is recording. True if any active
; microphone has an active session of the Claude Code process.
; Not the registry record behind the tray microphone icon (ConsentStore\microphone):
; since the Windows updates of October 2026 it is no longer written for
; ordinary (non-Store) programs.
MicInUse() {
    if !ClaudePid
        return false
    for session in AudioCaptureSessions()
        if (session.pid = ClaudePid && session.state = 1)
            return true
    return false
}

; Audio sessions on all active microphones, of every program: {pid, state, device},
; state 0 inactive, 1 active (recording), 2 expired; device is the microphone
; (IMMDevice) the session is on.
AudioCaptureSessions() {
    list := []
    ; Every interface pointer goes into a ComValue(13, 0) wrapper, which releases
    ; it when the wrapper is freed, also when a call fails halfway. A microphone
    ; that fails (unplugged during the loop) is skipped and the others are still
    ; listed, so one bad device does not read as "Claude Code stopped recording".
    try {
        ; IMMDeviceEnumerator::EnumAudioEndpoints(eCapture, DEVICE_STATE_ACTIVE)
        deviceEnumerator := ComObject("{BCDE0395-E52F-467C-8E3D-C4579291692E}", "{A95664D2-9614-4F35-A746-DE8DB63617E6}")
        devices := ComValue(13, 0)
        ComCall(3, deviceEnumerator, "int", 1, "uint", 1, "ptr*", devices)
        ComCall(3, devices, "uint*", &deviceCount := 0)
        managerIid := Buffer(16)
        DllCall("ole32\CLSIDFromString", "str", "{77AA99A0-1BD6-484F-8BC7-2C654C9A9B6F}", "ptr", managerIid)   ; IAudioSessionManager2
        Loop deviceCount {
            deviceIndex := A_Index - 1
            try {
                device := ComValue(13, 0)
                ComCall(4, devices, "uint", deviceIndex, "ptr*", device)                     ; Item
                manager := ComValue(13, 0)
                ComCall(3, device, "ptr", managerIid, "uint", 23, "ptr", 0, "ptr*", manager)   ; Activate
                sessions := ComValue(13, 0)
                ComCall(5, manager, "ptr*", sessions)                                       ; GetSessionEnumerator
                ComCall(3, sessions, "int*", &sessionCount := 0)
                Loop sessionCount {
                    control := ComValue(13, 0)
                    ComCall(4, sessions, "int", A_Index - 1, "ptr*", control)               ; GetSession
                    ComCall(3, control, "int*", &state := 0)                                ; GetState
                    control2 := ComObjQuery(control, "{bfb7ff88-7239-4fc9-8fa2-07c950be9c6d}")   ; IAudioSessionControl2
                    ComCall(14, control2, "uint*", &sessionPid := 0)                        ; GetProcessId
                    list.Push({pid: sessionPid, state: state, device: device})
                }
            }
        }
    }
    return list
}

; Full path of the executable behind the running Claude Code process, as the
; kernel sees it now; used by the update check below. Claude Code's auto-update
; renames the running binary (claude.exe -> claude.exe.old.<n>) and puts the
; new one in its place; the process keeps running under the new name.
; WMI / Get-Process still report the original path,
; QueryFullProcessImageName reports the current one. "" if the process is gone.
ClaudeImagePath() {
    if !ClaudePid
        return ""
    h := DllCall("OpenProcess", "uint", 0x1000, "int", 0, "uint", ClaudePid, "ptr")   ; PROCESS_QUERY_LIMITED_INFORMATION
    if !h
        return ""
    buf := Buffer(1024 * 2)
    size := 1024
    ok := DllCall("QueryFullProcessImageNameW", "ptr", h, "uint", 0, "ptr", buf, "uint*", &size)
    DllCall("CloseHandle", "ptr", h)
    return ok ? StrGet(buf, size, "UTF-16") : ""
}

; Claude Code updates itself in the background and says nothing about it: the
; old version keeps running under a new file name. Once the running path stops
; matching the one seen at start, the idle indicator turns yellow until a Reload.
; Checked once a minute; stops itself after the first hit.
CheckClaudeUpdate() {
    global ClaudeUpdated
    path := ClaudeImagePath()
    if (path = "" || ClaudeStartPath = "" || path = ClaudeStartPath)
        return
    ClaudeUpdated := true
    SetTimer CheckClaudeUpdate, 0
    LogEvent("Claude Code updated itself: running binary is now " path ", Reload to start the new version")
    if !Recording
        IndicatorIdle()
}

RecTick() {
    global MicSeen
    ; A hotkey can interrupt this timer anywhere (in MicInUse above all) and
    ; finish or cancel the recording; then the rest of this tick is stale.
    if !Recording
        return
    ; Claude Code stopped and submitted on its own (15 s of silence or its
    ; 2-minute cap): the hook has already written the file, so just paste it.
    if FileExist(OutFile) {
        StopRecClock()
        ClaudeSubmittedItself()
        return
    }
    elapsed := (A_TickCount - RecStartTick) // 1000
    micOn := MicInUse()
    if !Recording
        return
    if micOn {
        MarkMicOn()
    } else if MicSeen {
        ; The microphone went off without a file: either Claude Code is still
        ; transcribing (file follows shortly) or it gave up ("No speech detected").
        StopRecClock()
        ClaudeStoppedItself()
        return
    } else if (elapsed >= 5) {
        StopRecClock()
        global Recording := false
        ; Before the Escape: what Claude Code shows and who holds the microphone,
        ; to tell "the Space did not start a recording" from "the recording was
        ; not seen".
        LogMicDiagnostics()
        ; Cancel a start that is merely slow, so the microphone does not come on
        ; later with nobody waiting for the text.
        SendToClaude("{Escape}")
        LogEvent("mic never came on within 5 s, Escape sent")
        SetIndicator("No mic", "E05050", 3000)
        PlayCue("error")
        return
    }
    left := RecLimitSec - elapsed
    if (left <= RecForceStopAt) {
        StopRecClock()
        LogEvent("countdown reached " left " s, forcing stop")
        FinishDictation()
        return
    }
    ShowRecState()
}

; The indicator during a recording. Until the microphone is really on (0.2 to
; 1 second after the hotkey) it says "wait" in yellow: words spoken before
; that are lost. Then the countdown, green, red for the last RecWarnSec
; seconds and past zero.
ShowRecState() {
    if !MicSeen {
        SetIndicator("… wait", "E0B050")
        return
    }
    left := RecLimitSec - (A_TickCount - RecStartTick) // 1000
    a := Abs(left)
    SetIndicator("● REC " (left < 0 ? "-" : "") (a // 60) ":" Format("{:02}", Mod(a, 60)), (left <= RecWarnSec) ? "FF4040" : "60C060")
}

; ---- Claude Code window -------------------------------------------

; Starts Claude Code in a classic console (conhost) and remembers its window.
; Environment variables set here are inherited by the child process.
; conhost accepts posted keys whether the window is visible, minimized or hidden;
; Windows Terminal does not, which is why it is not used here.
StartClaudeWindow() {
    global DictHwnd, ClaudePid, ClaudeStartPath, ClaudeUpdated
    ; CLAUDE_CONFIG_DIR is set only for the Run below and put back right after:
    ; the launcher that switches profiles is started from this process and
    ; would otherwise hand the old profile down to a "default" core.
    inheritedConfigDir := EnvGet("CLAUDE_CONFIG_DIR")
    if (ConfigDir != "")
        EnvSet "CLAUDE_CONFIG_DIR", ConfigDir
    ; /voice needs a claude.ai login; make sure no API key overrides it,
    ; and that Claude Code is not switched to Bedrock, Vertex or Foundry,
    ; where /voice is not available.
    EnvSet "ANTHROPIC_API_KEY", ""
    EnvSet "ANTHROPIC_AUTH_TOKEN", ""
    EnvSet "CLAUDE_CODE_OAUTH_TOKEN", ""
    EnvSet "CLAUDE_CODE_USE_BEDROCK"
    EnvSet "CLAUDE_CODE_USE_VERTEX"
    EnvSet "CLAUDE_CODE_USE_FOUNDRY"

    Run 'conhost.exe "' ClaudeExe '" --settings "' Settings '"', A_ScriptDir, , &conhostPid
    if (inheritedConfigDir != "")
        EnvSet "CLAUDE_CONFIG_DIR", inheritedConfigDir
    else
        EnvSet "CLAUDE_CONFIG_DIR"
    ; The window is found through the processes, not as "a console window that
    ; was not there before": other programs open short-lived hidden consoles all
    ; the time, and one of them could be taken instead. conhost runs claude.exe
    ; as its child, and a console window reports the pid of the hosted program
    ; (claude.exe), not of conhost, so the window is the console window of that
    ; child. That pid is also what MicInUse and the update check work from.
    SplitPath ClaudeExe, &exeName
    DictHwnd := 0
    ClaudePid := 0
    Loop 150 {
        if !ClaudePid
            ClaudePid := ChildPid(conhostPid, exeName)
        if ClaudePid
            DictHwnd := WinExist("ahk_class ConsoleWindowClass ahk_pid " ClaudePid)
        if DictHwnd
            break
        Sleep 100
    }
    if !DictHwnd {
        ; Close what was started, or every failed start leaves a hidden
        ; Claude Code behind (OnExit only knows the window, and there is none).
        if ClaudePid
            ProcessClose ClaudePid
        ProcessClose conhostPid
        LogEvent("Claude Code window not found within 15 s (conhost pid " conhostPid ", " exeName " pid " ClaudePid ")")
        ClaudePid := 0
        return false
    }

    throttlingOff := DisablePowerThrottling(ClaudePid) && DisablePowerThrottling(conhostPid)
    Sleep 5000   ; let Claude Code draw its prompt
    ApplyWindowMode(WindowMode)
    EmptyClaudeInput()   ; erase what got typed into the console while it had the focus
    ClaudeStartPath := ClaudeImagePath()   ; "" if Claude Code crashed on startup
    ClaudeUpdated := false
    SetTimer CheckClaudeUpdate, 60000
    LogEvent("Claude Code started, console hwnd " DictHwnd ", pid " ClaudePid " (" ClaudeStartPath "), config " (ConfigDir != "" ? ConfigDir : "default") ", window " WindowMode ", power throttling " (throttlingOff ? "off" : "NOT turned off"))
    return true
}

; Windows slows down background processes to save power (power throttling,
; the "efficiency mode" of Task Manager). Claude Code and its console are
; always in the background, so after a long pause they could be slow to start
; a recording. This opts one process out: ControlMask names the kinds of
; throttling decided here (execution speed 1, timer resolution 4), StateMask 0
; turns them off. True if Windows accepted it.
DisablePowerThrottling(pid) {
    h := DllCall("OpenProcess", "uint", 0x0200, "int", 0, "uint", pid, "ptr")   ; PROCESS_SET_INFORMATION
    if !h
        return false
    state := Buffer(12, 0)              ; PROCESS_POWER_THROTTLING_STATE
    NumPut("uint", 1, state, 0)         ; Version
    NumPut("uint", 1 | 4, state, 4)     ; ControlMask
    NumPut("uint", 0, state, 8)         ; StateMask
    ok := DllCall("SetProcessInformation", "ptr", h, "int", 4, "ptr", state, "uint", 12)   ; ProcessPowerThrottling
    DllCall("CloseHandle", "ptr", h)
    return ok != 0
}

; Pid of the child process of parentPid with the given exe name, 0 if none (yet).
ChildPid(parentPid, name) {
    query := "SELECT ProcessId FROM Win32_Process WHERE ParentProcessId=" parentPid " AND Name='" name "'"
    for process in ComObjGet("winmgmts:").ExecQuery(query)
        return process.ProcessId
    return 0
}

ClaudeWindowAlive() {
    return DictHwnd && WinExist("ahk_id " DictHwnd)
}

CloseClaudeWindow(*) {
    if ClaudeWindowAlive() {
        WinShow "ahk_id " DictHwnd
        WinClose "ahk_id " DictHwnd
    }
}

; Posts keys into the Claude Code console without touching the focus.
SendToClaude(keys) {
    if !ClaudeWindowAlive()
        return false
    ControlSend keys, , "ahk_id " DictHwnd
    return true
}

; ---- event log ----------------------------------------------------

; Same file the hook writes to; script lines are tagged [ahk].
LogEvent(msg) {
    try FileAppend FormatTime(A_Now, "yyyy-MM-dd HH:mm:ss") "." A_MSec " [ahk] " msg "`n", LogFile, "UTF-8"
}

; ---- dictation ----------------------------------------------------

ToggleDictation() {
    global Recording, TargetHwnd
    if Busy
        return      ; the previous recording is still being collected and pasted
    if !Recording {
        pressTick := A_TickCount
        ; Time since the last keyboard or mouse event, normally the hotkey
        ; itself: shows whether Windows delivered the hotkey late.
        sinceKey := A_TimeIdle
        try TargetHwnd := WinGetID("A")
        catch
            TargetHwnd := 0
        SetTimer WatchLateText, 0
        CollectLateText(false)     ; a text that came too late is kept, not deleted
        try FileDelete OutFile
        if !ClaudeWindowAlive() && !StartClaudeWindow() {
            LogEvent("start failed: no Claude Code window")
            SetIndicator("No Claude", "E05050", 3000)
            PlayCue("error")
            return
        }
        EmptyClaudeInput()
        SendToClaude("{Space}")
        spaceMs := A_TickCount - pressTick
        Recording := true
        StartRecClock()
        LogEvent("recording started, target window " TargetHwnd " (" TargetTitle() "); hotkey seen " sinceKey " ms after the last key event, Space sent after " spaceMs " ms, REC shown after " (A_TickCount - pressTick) " ms")
    } else {
        LogEvent("stop requested by hotkey")
        FinishDictation()
    }
}

TargetTitle() {
    try return WinGetTitle("ahk_id " TargetHwnd)
    return ""
}

; Before the Space that starts a recording (and once after Claude Code starts).
; Anything left in Claude Code's input would turn the Space into a typed space
; instead of the start of a recording. Normally the input is empty: the hook
; stops a prompt with "continue": false, and then Claude Code leaves the input
; empty. Text is left there only when the hook failed to run (Claude Code puts
; a blocked prompt back into its input, seen on 2.1.310) or keys were typed
; into the visible console.
; So the window is read first, and only text found there is erased, with a
; line in the log; then it waits until the window shows the input empty: an
; erase sent right before the Space can reach Claude Code together with it,
; and the Space is typed again. Several attempts, as the text may still come
; back meanwhile. If the window cannot be read, the input counts as empty:
; then the erase could not be written either.
; Ctrl+U erases one screen line of the input, so the erase is one Ctrl+U per
; line the text takes, plus two in case it grew meanwhile; the extra ones hit
; an empty input and do nothing.
EmptyClaudeInput() {
    text := ClaudeInputText(&lineCount)
    if (text = "")
        return
    startTick := A_TickCount
    LogEvent("Claude Code input not empty (" lineCount " lines), sending Ctrl+U: " SubStr(text, 1, 100))
    Loop 3 {
        WriteCtrlU(lineCount + 2)
        Loop 10 {
            Sleep 50
            if (ClaudeInputText(&lineCount) = "") {
                LogEvent("Claude Code input empty after " (A_TickCount - startTick) " ms")
                return
            }
        }
    }
    LogEvent("could not empty Claude Code's input, starting anyway")
}

; Second press (or the countdown reaching zero): stop, wait for the hook, paste.
; Every way a recording ends sets Busy until the text is pasted: a Ctrl+Space
; pressed meanwhile is ignored instead of starting a
; new recording on top (it would take over TargetHwnd and delete the hook file).
; The countdown and the self-stop paths run from the RecTick timer, which a
; hotkey can interrupt, so the per-hotkey thread limit does not cover them.
FinishDictation() {
    global Recording, Busy
    Recording := false
    Busy := true
    try {
        StopRecClock()
        SetIndicator("… process", "E0B050")
        if !ClaudeWindowAlive() {
            LogEvent("stop failed: Claude Code window is gone")
            SetIndicator("No Claude", "E05050", 3000)
            PlayCue("error")
            return
        }
        PlayCue("stop")
        ; Only stop the recording if it is still running. If Claude Code already
        ; stopped by itself, a Space on an empty prompt would start a new recording.
        if MicInUse()
            SendToClaude("{Space}")
        else
            LogEvent("mic already off, Space not sent")
        DeliverText(WaitForTextOrEnter(6000, 6000), "No text", 3000)
    } finally
        Busy := false
}

; The microphone went off on its own and no file has arrived yet.
ClaudeStoppedItself() {
    global Recording, Busy
    Recording := false
    Busy := true
    try {
        LogEvent("mic went off by itself")
        SetIndicator("… process", "E0B050")
        PlayCue("auto")
        DeliverText(WaitForTextOrEnter(2500, 3000), "No speech", 2000)
    } finally
        Busy := false
}

; Claude Code ended the recording and submitted without our second Space.
ClaudeSubmittedItself() {
    global Recording, Busy
    Recording := false
    Busy := true
    try {
        LogEvent("Claude Code submitted by itself")
        SetIndicator("… process", "E0B050")
        PlayCue("auto")
        DeliverText(WaitForText(2000), "No text", 3000)
    } finally
        Busy := false
}

; Claude Code auto-submits transcripts of 3+ words. Shorter ones stay in the
; input, so if nothing arrives we press Enter once and wait again (on an empty
; input Enter does nothing).
WaitForTextOrEnter(firstMs, secondMs) {
    text := WaitForText(firstMs)
    if (text = "") {
        LogEvent("no text after " firstMs // 1000 " s, sending Enter")
        SendToClaude("{Enter}")
        text := WaitForText(secondMs)
    }
    return text
}

; Pastes the text if there is any, otherwise shows the given error state.
DeliverText(text, errorLabel, errorMs) {
    global LateUntil
    if (text = "") {
        LogEvent("nothing to paste: " errorLabel)
        SetIndicator(errorLabel, "E05050", errorMs)
        PlayCue("error")
        ; The text may still come (slow network): keep it then, see CollectLateText.
        LateUntil := A_TickCount + 90000
        SetTimer WatchLateText, 500
        return
    }
    RememberText(text)      ; before the paste, which can miss
    if !PasteText(text, TargetHwnd) {
        LogEvent("paste failed (clipboard), " StrLen(text) " chars kept for the repaste key")
        SetIndicator("No paste", "E05050", 3000)
        PlayCue("error")
        return
    }
    LogEvent("pasted " StrLen(text) " chars into " TargetHwnd " (" TargetTitle() ")")
    SetIndicator("✓ pasted", "60C060", 1500)
}

; Ctrl+U (delete to line start) as a key-down and key-up record in the input
; buffer of the Claude Code console. Not posted with ControlSend: to a console
; without the focus the Ctrl is lost and a plain "u" arrives. Not Backspaces:
; the console takes about 150 keys a second, so a long dictation would take
; seconds to erase. The script has no console of its own, so it attaches to
; that one for the call and detaches again. count presses go in one write.
WriteCtrlU(count := 1) {
    if !ClaudePid || !DllCall("AttachConsole", "uint", ClaudePid)
        return false
    input := DllCall("CreateFileW", "str", "CONIN$", "uint", 0xC0000000, "uint", 3, "ptr", 0, "uint", 3, "uint", 0, "ptr", 0, "ptr")
    if (input = -1) {   ; INVALID_HANDLE_VALUE
        DllCall("FreeConsole")
        return false
    }
    ; Per press two INPUT_RECORDs of 20 bytes: EventType KEY_EVENT, then KEY_EVENT_RECORD.
    records := Buffer(40 * count, 0)
    Loop count * 2 {
        keyDown := Mod(A_Index, 2)          ; down, up, down, up, ...
        offset := (A_Index - 1) * 20
        NumPut("ushort", 1, records, offset)              ; EventType = KEY_EVENT
        NumPut("int", keyDown, records, offset + 4)       ; bKeyDown
        NumPut("ushort", 1, records, offset + 8)          ; wRepeatCount
        NumPut("ushort", 0x55, records, offset + 10)      ; wVirtualKeyCode = U
        NumPut("ushort", 0x16, records, offset + 12)      ; wVirtualScanCode of U
        NumPut("ushort", 0x15, records, offset + 14)      ; UnicodeChar: Ctrl+U
        NumPut("uint", 0x08, records, offset + 16)        ; dwControlKeyState = LEFT_CTRL_PRESSED
    }
    written := 0
    ok := DllCall("WriteConsoleInputW", "ptr", input, "ptr", records, "uint", count * 2, "uint*", &written)
    DllCall("CloseHandle", "ptr", input)
    DllCall("FreeConsole")
    return ok && written = count * 2
}

; The last lineCount non-empty lines of the visible part of the Claude Code
; console, attached the same way as WriteCtrlU. Empty if it cannot be read.
ReadClaudeConsole(lineCount) {
    ; A hotkey meanwhile would call WriteCtrlU, whose AttachConsole fails
    ; while this script is still attached.
    Critical
    lines := []
    if !ClaudePid || !DllCall("AttachConsole", "uint", ClaudePid)
        return lines
    output := DllCall("CreateFileW", "str", "CONOUT$", "uint", 0xC0000000, "uint", 3, "ptr", 0, "uint", 3, "uint", 0, "ptr", 0, "ptr")
    if (output != -1) {   ; INVALID_HANDLE_VALUE
        ; CONSOLE_SCREEN_BUFFER_INFO: buffer width at 0, visible window
        ; (Left, Top, Right, Bottom) at 10.
        info := Buffer(22, 0)
        if DllCall("GetConsoleScreenBufferInfo", "ptr", output, "ptr", info) {
            width := NumGet(info, 0, "short")
            top := NumGet(info, 12, "short")
            bottom := NumGet(info, 16, "short")
            row := Buffer(width * 2)
            y := bottom
            while (y >= top && lines.Length < lineCount) {
                read := 0
                ; The COORD {X 0, Y y} goes by value as one 32-bit number.
                DllCall("ReadConsoleOutputCharacterW", "ptr", output, "ptr", row, "uint", width, "uint", y << 16, "uint*", &read)
                text := RTrim(StrGet(row, read, "UTF-16"))
                if (text != "")
                    lines.InsertAt(1, text)
                y--
            }
        }
        DllCall("CloseHandle", "ptr", output)
    }
    DllCall("FreeConsole")
    return lines
}

; Text in Claude Code's input box: the lines between its lower and upper
; border (lines of "─"), without the ">" prompt. A long text wraps over many
; lines, so the box is found from its lower border up, not by the ">" line,
; which can be far above the bottom. The prompt is drawn as ">" or "❯".
; An empty input shows a grey hint like Try "how do I log an error?", which
; counts as empty. "" if the input is empty or the window cannot be read.
; lineCount gets the number of screen lines the text takes.
ClaudeInputText(&lineCount := 0) {
    lines := ReadClaudeConsole(40)
    text := ""
    lineCount := 0
    insideBox := false
    Loop lines.Length {
        line := lines[lines.Length - A_Index + 1]
        if (SubStr(line, 1, 1) = "─") {
            if insideBox
                break           ; upper border
            insideBox := true   ; lower border; the status lines under it are skipped
            continue
        }
        if !insideBox
            continue
        isPromptLine := (SubStr(line, 1, 1) = ">" || SubStr(line, 1, 1) = "❯")
        if isPromptLine
            line := SubStr(line, 2)
        text := Trim(line, " `t" Chr(0xA0)) " " text   ; the prompt is followed by a no-break space
        lineCount++
        if isPromptLine
            break
    }
    text := Trim(text)
    if (text = "" || RegExMatch(text, '^Try "[^"]*"$')) {
        lineCount := 0
        return ""
    }
    return text
}

; The microphone did not come on: log every audio session on the microphones
; (whose it is and its state, 1 = recording) and the bottom of the Claude Code
; window, where its input line and voice status are.
LogMicDiagnostics() {
    sessions := ""
    for session in AudioCaptureSessions() {
        name := "?"
        try name := ProcessGetName(session.pid)
        sessions .= ", " name " pid " session.pid " state " session.state
    }
    LogEvent("microphone sessions (Claude Code pid " ClaudePid "): " (sessions != "" ? SubStr(sessions, 3) : "none"))
    lines := ReadClaudeConsole(10)
    if (lines.Length = 0)
        LogEvent("Claude Code window could not be read")
    for line in lines
        LogEvent("console: " line)
}

; Escape inside Claude Code aborts the recording: nothing is submitted,
; the hook does not run. Verified by hand on 2.1.257.
CancelDictation() {
    global Recording
    Recording := false
    StopRecClock()
    SendToClaude("{Escape}")
    LogEvent("cancelled by Escape")
    SetIndicator("✕ ESC", "E0A040", 1500)
}

WaitForText(timeoutMs) {
    start := A_TickCount
    while (A_TickCount - start < timeoutMs) {
        if FileExist(OutFile)
            return ReadOutFile()
        Sleep 100
    }
    return ""
}

; The text the hook wrote; the file is removed.
ReadOutFile() {
    Sleep 50
    text := ""
    try text := FileRead(OutFile, "UTF-8")
    try FileDelete OutFile
    return Trim(text, " `t`r`n")
}

; Pastes into the given window (the active one if it is gone). False if the
; clipboard did not take the text.
PasteText(text, hwnd) {
    saved := ClipboardAll()
    try {
        A_Clipboard := text
        if !ClipWait(1)
            return false
        if (hwnd && WinExist("ahk_id " hwnd)) {
            try WinActivate "ahk_id " hwnd   ; the window may close in between
            WinWaitActive("ahk_id " hwnd, , 2)
        }
        Send "^v"
        Sleep 500
        return true
    } finally
        A_Clipboard := saved   ; restore whatever the user had in the clipboard, on every path
}
