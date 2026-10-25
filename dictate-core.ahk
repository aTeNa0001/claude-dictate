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
    global Indicator, IndText
    ; -Caption: no frame; +ToolWindow: no taskbar button.
    Indicator := Gui("+AlwaysOnTop -Caption +ToolWindow +Owner", "claude-dictate indicator")
    Indicator.BackColor := "1E1E1E"
    Indicator.MarginX := 10
    Indicator.MarginY := 5
    Indicator.SetFont("s10 bold", "Segoe UI")
    IndText := Indicator.AddText("w88 Center c" IndState.color, IndState.text)
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
    OnMessage 0x0232, OnIndicatorMoved       ; WM_EXITSIZEMOVE: drag finished
    Indicator.OnEvent("ContextMenu", (*) => A_TrayMenu.Show())   ; right-click: same menu as the tray icon
}

; Left button on the indicator: let Windows drag it as if by its title bar.
OnIndicatorMouseDown(wParam, lParam, msg, hwnd) {
    if (hwnd != Indicator.Hwnd)
        return
    PostMessage 0x00A1, 2, 0, , Indicator      ; WM_NCLBUTTONDOWN, HTCAPTION
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
    global Indicator
    try Indicator.Destroy()
    CreateIndicator()
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
    global RecStartTick, MicSeen
    RecStartTick := A_TickCount
    MicSeen := false
    RecTick()
    SetTimer RecTick, 1000
}

StopRecClock() {
    SetTimer RecTick, 0
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
    ; Every interface pointer goes into a ComValue(13, 0) wrapper, which releases
    ; it when the wrapper is freed, also when a call fails halfway. A microphone
    ; that fails (unplugged during the loop) is skipped and the others are still
    ; checked, so one bad device does not read as "Claude Code stopped recording".
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
                    if (sessionPid = ClaudePid && state = 1)
                        return true
                }
            }
        }
    }
    return false
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
        MicSeen := true
    } else if MicSeen {
        ; The microphone went off without a file: either Claude Code is still
        ; transcribing (file follows shortly) or it gave up ("No speech detected").
        StopRecClock()
        ClaudeStoppedItself()
        return
    } else if (elapsed >= 5) {
        StopRecClock()
        global Recording := false
        ; Cancel a start that is merely slow, so the microphone does not come on
        ; later with nobody waiting for the text.
        SendToClaude("{Escape}")
        LogEvent("mic never came on within 5 s, Escape sent")
        SetIndicator("No mic", "E05050", 3000)
        return
    }
    left := RecLimitSec - elapsed
    if (left <= RecForceStopAt) {
        StopRecClock()
        LogEvent("countdown reached " left " s, forcing stop")
        FinishDictation()
        return
    }
    ; green while recording, red for the last RecWarnSec seconds and past zero
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

    Sleep 5000   ; let Claude Code draw its prompt
    ApplyWindowMode(WindowMode)
    WriteCtrlU()   ; erase what got typed into the console while it had the focus
    ClaudeStartPath := ClaudeImagePath()   ; "" if Claude Code crashed on startup
    ClaudeUpdated := false
    SetTimer CheckClaudeUpdate, 60000
    LogEvent("Claude Code started, console hwnd " DictHwnd ", pid " ClaudePid " (" ClaudeStartPath "), config " (ConfigDir != "" ? ConfigDir : "default") ", window " WindowMode)
    return true
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
    try FileAppend FormatTime(A_Now, "yyyy-MM-dd HH:mm:ss") " [ahk] " msg "`n", LogFile, "UTF-8"
}

; ---- dictation ----------------------------------------------------

ToggleDictation() {
    global Recording, TargetHwnd
    if Busy
        return      ; the previous recording is still being collected and pasted
    if !Recording {
        try TargetHwnd := WinGetID("A")
        catch
            TargetHwnd := 0
        try FileDelete OutFile
        if !ClaudeWindowAlive() && !StartClaudeWindow() {
            LogEvent("start failed: no Claude Code window")
            SetIndicator("No Claude", "E05050", 3000)
            return
        }
        ; Anything left in Claude Code's input (a prompt it put back after a
        ; failed paste, keys typed into the visible console) would turn the
        ; Space into a typed space instead of the start of a recording.
        WriteCtrlU()
        SendToClaude("{Space}")
        Recording := true
        StartRecClock()
        LogEvent("recording started, target window " TargetHwnd " (" TargetTitle() ")")
    } else {
        LogEvent("stop requested by hotkey")
        FinishDictation()
    }
}

TargetTitle() {
    try return WinGetTitle("ahk_id " TargetHwnd)
    return ""
}

; Second press (or the countdown reaching zero): stop, wait for the hook, paste.
; Every way a recording ends sets Busy until the text is pasted and Claude Code's
; input erased: a Ctrl+Space pressed meanwhile is ignored instead of starting a
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
            return
        }
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
    if (text = "") {
        LogEvent("nothing to paste: " errorLabel)
        SetIndicator(errorLabel, "E05050", errorMs)
        return
    }
    PasteText(text)
    LogEvent("pasted " StrLen(text) " chars into " TargetHwnd " (" TargetTitle() ")")
    SetIndicator("✓ pasted", "60C060", 1500)
    ClearClaudeInput()
}

; Claude Code puts a prompt blocked by the hook back into its input (seen on
; 2.1.310), so it is erased after pasting: otherwise the next dictation is
; appended to it, and a Space on a non-empty input types a space instead of
; starting a recording.
; Claude Code puts the text back once the hook has exited, which is after the
; hook file appeared (the hook runs as bash -> bash -> powershell), so first
; wait until no process with hook-grab.ps1 in its command line is left.
; Erased with Ctrl+U (delete to line start; on an empty input it does nothing),
; written straight into the console's input buffer: posted with ControlSend to
; a console without the focus, the Ctrl is lost and a plain "u" arrives, and
; Backspaces are too slow (the console takes about 150 keys a second, so a
; long dictation would take seconds to erase).
ClearClaudeInput() {
    ; A Ctrl+Space pressed meanwhile waits until the input is erased.
    Critical
    hookDone := false
    Loop 30 {
        if !HookRunning() {
            hookDone := true
            break
        }
        Sleep 100
    }
    if !hookDone
        LogEvent("hook still running after 3 s, erasing anyway; the next start erases again")
    Sleep 200          ; the text comes back right after the hook exits
    if !WriteCtrlU()
        LogEvent("could not erase Claude Code's input (WriteConsoleInput failed)")
}

; Ctrl+U as a key-down and key-up record in the input buffer of the Claude Code
; console. The script has no console of its own, so it attaches to that one
; for the call and detaches again.
WriteCtrlU() {
    if !ClaudePid || !DllCall("AttachConsole", "uint", ClaudePid)
        return false
    input := DllCall("CreateFileW", "str", "CONIN$", "uint", 0xC0000000, "uint", 3, "ptr", 0, "uint", 3, "uint", 0, "ptr", 0, "ptr")
    if (input = -1) {   ; INVALID_HANDLE_VALUE
        DllCall("FreeConsole")
        return false
    }
    ; Two INPUT_RECORDs of 20 bytes: EventType KEY_EVENT, then KEY_EVENT_RECORD.
    records := Buffer(40, 0)
    for index, keyDown in [1, 0] {
        offset := (index - 1) * 20
        NumPut("ushort", 1, records, offset)              ; EventType = KEY_EVENT
        NumPut("int", keyDown, records, offset + 4)       ; bKeyDown
        NumPut("ushort", 1, records, offset + 8)          ; wRepeatCount
        NumPut("ushort", 0x55, records, offset + 10)      ; wVirtualKeyCode = U
        NumPut("ushort", 0x16, records, offset + 12)      ; wVirtualScanCode of U
        NumPut("ushort", 0x15, records, offset + 14)      ; UnicodeChar: Ctrl+U
        NumPut("uint", 0x08, records, offset + 16)        ; dwControlKeyState = LEFT_CTRL_PRESSED
    }
    written := 0
    ok := DllCall("WriteConsoleInputW", "ptr", input, "ptr", records, "uint", 2, "uint*", &written)
    DllCall("CloseHandle", "ptr", input)
    DllCall("FreeConsole")
    return ok && written = 2
}

; Matches the hook command from dictate-settings.json, not just the file name,
; so an editor with hook-grab.ps1 open does not count as a running hook.
HookRunning() {
    for process in ComObjGet("winmgmts:").ExecQuery("SELECT ProcessId FROM Win32_Process WHERE CommandLine LIKE '%-File hook-grab.ps1%'")
        return true
    return false
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
        if FileExist(OutFile) {
            Sleep 50
            text := FileRead(OutFile, "UTF-8")
            try FileDelete OutFile
            return Trim(text, " `t`r`n")
        }
        Sleep 100
    }
    return ""
}

PasteText(text) {
    global TargetHwnd
    saved := ClipboardAll()
    try {
        A_Clipboard := text
        if !ClipWait(1)
            return
        if (TargetHwnd && WinExist("ahk_id " TargetHwnd)) {
            try WinActivate "ahk_id " TargetHwnd   ; the window may close in between
            WinWaitActive("ahk_id " TargetHwnd, , 2)
        }
        Send "^v"
        Sleep 500
    } finally
        A_Clipboard := saved   ; restore whatever the user had in the clipboard, on every path
}
