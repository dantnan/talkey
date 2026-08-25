#Requires AutoHotkey v2.0
#SingleInstance Force
Persistent
; Talkey - push-to-talk dictation for Windows.
;   <primary hotkey>   (1st press) start recording  /  (2nd press) stop + transcribe
;   <secondary hotkey> same, in the secondary language
; The text goes to the CLIPBOARD only. Paste it yourself with Ctrl+V.
; All settings live in config.ini next to this script.

; Declared global at script level so every function below can see them.
global CFG := A_ScriptDir "\config.ini"

; The venv always lives beside this script, so the path is derived rather than
; configured: IniRead decodes as ANSI, which would mangle a UTF-8 config value
; on an account like C:\Users\Ayse Oz\... and break the lookup. Everything read
; from config.ini below is plain ASCII.
global PYW := A_ScriptDir "\venv\Scripts\pythonw.exe"
global MODEL := IniRead(CFG, "whisper", "model", "medium")
global MUTE_OUTPUT := IniRead(CFG, "audio", "mute_output", "1")
global DONE_SOUND := IniRead(CFG, "audio", "done_sound", "1")
global L_PRI := IniRead(CFG, "lang", "primary", "tr")
global L_SEC := IniRead(CFG, "lang", "secondary", "en")
global K_PRI := IniRead(CFG, "hotkeys", "primary", "F8")
global K_SEC := IniRead(CFG, "hotkeys", "secondary", "F9")

global WORK := A_Temp "\talkey"
DirCreate(WORK)
global WAV := WORK "\rec.wav"
global STOPF := WORK "\rec.stop"
global READYF := WORK "\rec.ready"
global OUTF := WORK "\out.txt"

global recording := false
global busy := false
global recPid := 0
global recLang := L_PRI
global lastText := ""
global prevMute := ""   ; system mute state from before we silenced it

; ---------- notifications ----------
; A tooltip rather than TrayTip: it shows up instantly and does not depend on
; Windows notification settings, which are off on plenty of machines.
ClearTip() {
    ToolTip()
}

Notify(msg, ms := 2500) {
    ToolTip(msg)
    SetTimer(ClearTip, -ms)
}

; ---------- speaker muting ----------
; Silence the speakers while recording so whatever is playing does not bleed
; into the microphone. The previous state is remembered and put back, so a
; deliberately muted machine stays muted afterwards.
MuteOutput() {
    global prevMute
    if (MUTE_OUTPUT != "1")
        return
    try {
        prevMute := SoundGetMute()
        if !prevMute
            SoundSetMute(true)
    } catch {
        prevMute := ""      ; no default output device, nothing to do
    }
}

; A short chime once the text is actually on the clipboard, so you do not have
; to look at the screen to know it is ready. Runs after the speakers are back.
; "*64" is the system information sound, so it follows the user's sound scheme
; instead of hardcoding a file that may not exist.
DoneSound() {
    if (DONE_SOUND != "1")
        return
    try SoundPlay("*64")
}

RestoreOutput() {
    global prevMute
    if (prevMute = "")
        return
    try {
        if !prevMute
            SoundSetMute(false)
    }
    prevMute := ""
}

; ---------- recording ----------
StartRec(lang) {
    global recording, recPid, recLang
    for f in [WAV, STOPF, READYF, OUTF] {
        try FileDelete(f)
    }
    cmd := '"' PYW '" "' A_ScriptDir '\talkey-record.py" "' WAV '" "' STOPF '" "' READYF '"'
    try {
        Run(cmd, A_ScriptDir, "Hide", &pid)
    } catch as err {
        Notify("Could not start recording: " err.Message, 6000)
        return
    }
    recPid := pid
    recLang := lang
    ; Wait for the microphone to actually open, so "dinliyorum" is not a lie
    ; and the first word does not get clipped.
    deadline := A_TickCount + 6000
    while (!FileExist(READYF) && A_TickCount < deadline) {
        if !ProcessExist(recPid) {
            RestoreOutput()
            Notify("Microphone would not open. See " A_ScriptDir "\record.log", 8000)
            recPid := 0
            return
        }
        Sleep(50)
    }
    if !FileExist(READYF) {
        RestoreOutput()
        Notify("Microphone timed out. See " A_ScriptDir "\record.log", 8000)
        try ProcessClose(recPid)
        recPid := 0
        return
    }
    recording := true
    MuteOutput()
    A_IconTip := "Talkey - recording [" lang "]"
    Notify("🎤 listening [" lang "]... (same key to stop)", 3000)
}

StopAndTranscribe() {
    global recording, busy, recPid, recLang, lastText
    recording := false
    busy := true
    A_IconTip := "Talkey - transcribing"
    FileAppend("stop", STOPF)   ; sentinel: the recorder closes the WAV cleanly
    if recPid
        ProcessWaitClose(recPid, 10)
    recPid := 0
    RestoreOutput()   ; nothing is being recorded any more

    ; 44 bytes of header plus ~100 ms of 16 kHz mono s16 audio.
    if (!FileExist(WAV) || FileGetSize(WAV) < 3300) {
        Notify("empty recording", 2500)
        Done()
        return
    }

    Notify("transcribing...", 120000)
    cmd := '"' PYW '" "' A_ScriptDir '\talkey-client.py" ' recLang ' ' MODEL ' "' WAV '" "' OUTF '"'
    code := RunWait(cmd, A_ScriptDir, "Hide")

    if (code = 3) {
        Notify("Could not start the daemon. See " A_ScriptDir "\daemon.log", 8000)
        Done()
        return
    }
    if (code != 0) {
        Notify("Transcription failed (exit " code "). See " A_ScriptDir "\client.log", 8000)
        Done()
        return
    }

    text := ""
    try text := Trim(FileRead(OUTF, "UTF-8"))
    if (text = "") {
        Notify("nothing recognised", 2500)
        Done()
        return
    }
    A_Clipboard := text
    ClipWait(1)
    lastText := text
    DoneSound()
    Notify("📋 Copied (Ctrl+V): " SubStr(text, 1, 70), 4000)
    Done()
}

Done() {
    global busy
    busy := false
    A_IconTip := "Talkey - ready (" K_PRI "=" L_PRI ", " K_SEC "=" L_SEC ")"
}

Toggle(lang) {
    global recording, busy
    if busy {
        Notify("still transcribing the previous recording...", 2000)
        return
    }
    if recording
        StopAndTranscribe()
    else
        StartRec(lang)
}

; ---------- tray ----------
CopyLast(*) {
    if (lastText = "") {
        Notify("nothing dictated yet", 2000)
        return
    }
    A_Clipboard := lastText
    Notify("📋 last text copied", 2000)
}

RestartDaemon(*) {
    RunWait('powershell -NoProfile -ExecutionPolicy Bypass -File "' A_ScriptDir '\restart-daemon.ps1"', A_ScriptDir, "Hide")
    Notify("daemon restarted, loading the model", 4000)
}

OpenFolder(*) {
    Run(A_ScriptDir)
}

tray := A_TrayMenu
tray.Delete()
tray.Add("Copy last text", CopyLast)
tray.Add("Restart daemon", RestartDaemon)
tray.Add("Open install folder", OpenFolder)
tray.Add()
tray.Add("Exit", (*) => (RestoreOutput(), ExitApp()))

; ---------- start ----------
if !FileExist(PYW) {
    MsgBox("Python not found:`n" PYW "`n`nRun install.ps1 first.", "Talkey", "Iconx")
    ExitApp()
}

try {
    Hotkey(K_PRI, (*) => Toggle(L_PRI))
    Hotkey(K_SEC, (*) => Toggle(L_SEC))
} catch as err {
    MsgBox("Could not register the hotkeys (" K_PRI " / " K_SEC "):`n" err.Message, "Talkey", "Iconx")
    ExitApp()
}

Done()
Notify("Talkey ready: " K_PRI " = " L_PRI ", " K_SEC " = " L_SEC, 4000)
