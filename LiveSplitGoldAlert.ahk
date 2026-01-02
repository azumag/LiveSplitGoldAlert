#Requires AutoHotkey v2.0
#SingleInstance Force

; 管理者権限チェック
if !A_IsAdmin {
    try {
        Run '*RunAs "' A_ScriptFullPath '"'
    }
    ExitApp
}

; LiveSplit接続設定
LiveSplitHost := "127.0.0.1"
LiveSplitPort := 16834
PreviousSplitIndex := -1
PreviousDelta := ""
DebugMode := true  ; デバッグモード
CheckInterval := 2000  ; チェック間隔（ミリ秒）- 2秒に1回
LastCheckTime := 0
CachedSplitIndex := -1
AutoHideDelay := 10000  ; 自動非表示までの時間（ミリ秒）- 10秒
IsVideoVisible := false  ; 動画が表示されているか

; 定期的にチェック
SetTimer CheckGold, CheckInterval

; デバッグログ
DebugLog(msg) {
    global DebugMode
    if (DebugMode) {
        OutputDebug msg
        ToolTip msg
        SetTimer () => ToolTip(), -3000  ; 3秒後に消す

        ; ファイルにもログを残す
        try {
            logFile := A_ScriptDir . "\debug.log"
            timestamp := FormatTime(, "yyyy-MM-dd HH:mm:ss")
            FileAppend timestamp . " | " . msg . "`n", logFile
        }
    }
}

; LiveSplitにTCPソケット経由でコマンドを送信（PowerShell経由）
SendLiveSplitCommand(command) {
    global LiveSplitHost, LiveSplitPort

    ; PowerShellスクリプトを一時ファイルに作成
    psScript := (
        "try {`n"
        "    `$client = New-Object System.Net.Sockets.TcpClient`n"
        "    `$client.Connect('" . LiveSplitHost . "', " . LiveSplitPort . ")`n"
        "    `$stream = `$client.GetStream()`n"
        "    `$writer = New-Object System.IO.StreamWriter(`$stream)`n"
        "    `$reader = New-Object System.IO.StreamReader(`$stream)`n"
        "    `$writer.AutoFlush = `$true`n"
        "    `$writer.WriteLine('" . command . "')`n"
        "    Start-Sleep -Milliseconds 100`n"
        "    if (`$stream.DataAvailable) {`n"
        "        `$response = `$reader.ReadLine()`n"
        "        Write-Output `$response`n"
        "    }`n"
        "    `$client.Close()`n"
        "} catch {`n"
        "    Write-Output ''`n"
        "}`n"
    )

    ; 一時ファイルに保存
    tempFile := A_Temp . "\livesplit_cmd.ps1"
    try {
        file := FileOpen(tempFile, "w")
        file.Write(psScript)
        file.Close()

        ; PowerShellを完全にバックグラウンドで実行
        shell := ComObject("WScript.Shell")

        ; 出力ファイルを作成
        outputFile := A_Temp . "\livesplit_output.txt"

        ; PowerShellを実行（vbHide = 0で完全非表示、waitOnReturn = true）
        cmdLine := "powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -NoProfile -Command `"& '" . tempFile . "' | Out-File -Encoding UTF8 '" . outputFile . "'`""
        shell.Run(cmdLine, 0, true)

        ; 出力ファイルを読み取り
        if FileExist(outputFile) {
            outputFileObj := FileOpen(outputFile, "r")
            output := outputFileObj.Read()
            outputFileObj.Close()

            ; 出力ファイルを削除
            try {
                FileDelete(outputFile)
            }

            return Trim(output, "`r`n `t")
        }

        return ""
    } catch as err {
        DebugLog("Command error: " . err.Message)
        return ""
    }
}

CheckGold() {
    global PreviousSplitIndex, PreviousDelta, LastCheckTime, CachedSplitIndex

    ; レート制限: 最後のチェックから500ms以内は何もしない
    currentTime := A_TickCount
    if (currentTime - LastCheckTime < 500) {
        return
    }
    LastCheckTime := currentTime

    try {
        ; デルタを直接取得（スプリットインデックスが取得できないため）
        delta := SendLiveSplitCommand("getdelta")

        ; 初回起動時: PreviousDeltaを初期化するだけで終了
        if (PreviousDelta == "") {
            PreviousDelta := delta
            DebugLog("Initial delta set: [" . delta . "]")
            return
        }

        ; デルタが変わった場合（新しいスプリット）
        if (delta != "" && delta != PreviousDelta) {
            DebugLog("=== DELTA CHANGE DETECTED ===")
            DebugLog("Previous: [" . PreviousDelta . "]")
            DebugLog("Current:  [" . delta . "]")

            ; 重要: マイナスで始まり、かつ時刻形式がある場合のみゴールド判定
            ; ハイフンだけ（"-"）や時刻形式がないものは無視
            isNewNegative := (SubStr(delta, 1, 1) == "-" && StrLen(delta) > 1 && InStr(delta, ":"))

            DebugLog("isNewNegative: " . (isNewNegative ? "YES" : "NO") . " (length: " . StrLen(delta) . ")")

            ; デルタが変わって、新しい値がマイナスならゴールド判定
            ; （前回がマイナスでも、新しいスプリットでマイナスなら2回目のゴールド）
            if (isNewNegative) {
                DebugLog(">>> GOLD SPLIT DETECTED! (delta is negative) <<<")

                ; 少し待ってから再度確認
                Sleep 300

                ; 再確認
                delta2 := SendLiveSplitCommand("getdelta")
                DebugLog("Re-check delta: [" . delta2 . "]")

                if (delta2 == delta) {
                    DebugLog("*** CONFIRMED GOLD - Triggering alert! ***")
                    CheckForGoldSimple(delta, 0)
                } else {
                    DebugLog("Delta changed during re-check - skipping")
                }
            } else {
                DebugLog("Delta changed but not gold (positive or invalid format)")
            }

            PreviousDelta := delta
        }
    } catch as err {
        ; エラーは無視（接続できない場合など）
    }
}

CheckForGoldSimple(delta, splitIndex) {
    ; デルタがマイナスならゴールド
    DebugLog("Checking delta: [" . delta . "] (Length: " . StrLen(delta) . ") for split " . splitIndex)

    isGold := false
    reason := ""

    ; デバッグ: 文字列の各文字をチェック
    if (StrLen(delta) > 0) {
        DebugLog("First char code: " . Ord(SubStr(delta, 1, 1)))
    }

    ; 複数の方法でゴールドを検出
    ; 方法1: マイナス記号があればゴールド（時間フォーマットも含む）
    if (InStr(delta, "-")) {
        isGold := true
        reason := "Negative delta detected"
    }

    ; 方法2: 先頭がマイナス記号かチェック
    if (SubStr(delta, 1, 1) == "-") {
        isGold := true
        reason := "Starts with minus"
    }

    ; 方法3: Unicode のマイナス記号もチェック (U+2212)
    if (InStr(delta, "−")) {
        isGold := true
        reason := "Unicode minus detected"
    }

    DebugLog("Gold check: " . (isGold ? "YES - " . reason : "NO"))

    if (isGold) {
        DebugLog("!!! GOLD SPLIT DETECTED !!! Sending hotkey to OBS...")

        global AutoHideDelay, IsVideoVisible

        ; 既存の自動非表示タイマーをキャンセル
        SetTimer AutoHideGold, 0

        ; 既に動画が表示されている場合は、一度非表示にしてから再表示
        if (IsVideoVisible) {
            DebugLog("Video already visible - hiding first, then showing again")
            SendGoldHotkey()  ; 1回目: 非表示
            Sleep 200  ; 少し待つ
            SendGoldHotkey()  ; 2回目: 表示
        } else {
            DebugLog("Video not visible - showing now")
            SendGoldHotkey()  ; 表示
        }

        ; 動画が表示されている状態にする
        IsVideoVisible := true

        ; 10秒後に自動的に非表示にする
        SetTimer AutoHideGold, -AutoHideDelay

        TrayTip "Gold Split!", "Video will auto-hide in 10 seconds`n" . reason . "`nDelta: " . delta, 1

        ; 音も鳴らす
        SoundBeep 1000, 200
    }
}

; ホットキーを送信する関数
SendGoldHotkey() {
    DebugLog("Sending gold hotkey to OBS...")

    ; 複数の方法でホットキーを送信
    try {
        ; 方法1: SendPlay (ハードウェアレベルの送信 - 最も確実)
        SendPlay "^+!g"
        Sleep 100

        ; 方法2: SendEvent (イベント方式)
        SendEvent "^+!g"
        Sleep 100

        ; 方法3: SendInput (最速)
        SendInput "^+!g"
        Sleep 100

        ; 方法4: PostMessage/SendMessage経由でOBSに直接送信
        if WinExist("ahk_exe obs64.exe") {
            ControlSend "^+!g", , "ahk_exe obs64.exe"
            DebugLog("Sent via ControlSend to OBS")
        }

        DebugLog("Hotkey sent using multiple methods")
    }
}

; 自動非表示タイマー
AutoHideGold() {
    global IsVideoVisible

    DebugLog("Auto-hiding gold video after 10 seconds...")
    SendGoldHotkey()
    IsVideoVisible := false  ; 動画を非表示にした
    DebugLog("Auto-hide complete")
}

; TCPソケット接続テスト
TestTCPConnection() {
    global LiveSplitHost, LiveSplitPort

    commands := ["getcurrentsplitindex", "getdelta", "getlastsplittime", "getcurrenttime", "getfinaltime"]
    results := "Testing TCP connection to " . LiveSplitHost . ":" . LiveSplitPort . "`n`n"

    for index, cmd in commands {
        result := SendLiveSplitCommand(cmd)
        if (result != "") {
            results .= cmd . ": " . result . "`n"
        } else {
            results .= cmd . ": [No response]`n"
        }
        Sleep 100
    }

    MsgBox results, "TCP Connection Test", 64
    return results
}

; 接続テスト
^!v::TestTCPConnection()

; 手動でゴールド検出テスト
^!t:: {
    try {
        DebugLog("=== Manual test - getting current state ===")

        splitIndex := SendLiveSplitCommand("getcurrentsplitindex")
        delta := SendLiveSplitCommand("getdelta")
        lastSplit := SendLiveSplitCommand("getlastsplittime")
        comparison := SendLiveSplitCommand("getcomparisonsplittime")

        info := (
            "Split Index: [" . splitIndex . "]`n"
            "Delta: [" . delta . "]`n"
            "Last Split Time: [" . lastSplit . "]`n"
            "Comparison Time: [" . comparison . "]`n`n"
            "Delta Length: " . StrLen(delta) . "`n"
        )

        if (StrLen(delta) > 0) {
            info .= "First char: [" . SubStr(delta, 1, 1) . "] (Code: " . Ord(SubStr(delta, 1, 1)) . ")`n"

            ; 全文字のコードも表示
            info .= "`nAll chars: "
            Loop StrLen(delta) {
                char := SubStr(delta, A_Index, 1)
                info .= "[" . char . ":" . Ord(char) . "] "
            }
        }

        ; クリップボードにコピー
        A_Clipboard := info
        DebugLog(info)

        MsgBox info . "`n`n(Copied to clipboard!)", "Manual Test Results", 64

        if (delta != "") {
            CheckForGoldSimple(delta, 0)
        } else {
            MsgBox "No data received from LiveSplit Server.`n`nMake sure:`n1. LiveSplit is running`n2. LiveSplit Server component is added to layout`n3. Port is set to 16834", "Connection Failed", 48
        }
    } catch as err {
        DebugLog("Test error: " . err.Message)
        MsgBox "Error: " . err.Message, "Test Error", 16
    }
}

; デバッグモードの切り替え
^!d:: {
    global DebugMode
    DebugMode := !DebugMode
    DebugLog("Debug mode: " . (DebugMode ? "ON" : "OFF"))
}

; ログファイルを開く
^!l:: {
    logFile := A_ScriptDir . "\debug.log"
    if FileExist(logFile) {
        Run "notepad.exe `"" . logFile . "`""
    } else {
        MsgBox "Log file not found: " . logFile, "No Log", 48
    }
}

; ログファイルをクリア
^!c:: {
    logFile := A_ScriptDir . "\debug.log"
    try {
        FileDelete logFile
        MsgBox "Log file cleared!", "Success", 64
    } catch {
        MsgBox "Could not clear log file", "Error", 16
    }
}

; ホットキー送信テスト
^!h:: {
    DebugLog("Testing hotkey send...")

    obsRunning := WinExist("ahk_exe obs64.exe")
    isAdmin := A_IsAdmin ? "YES" : "NO"

    msg := (
        "Press OK, then the hotkey will be sent in 2 seconds.`n`n"
        "Status:`n"
        "- Running as Admin: " . isAdmin . "`n"
        "- OBS Detected: " . (obsRunning ? "YES" : "NO") . "`n`n"
        "Make sure OBS is open and check if the hotkey is received."
    )

    MsgBox msg, "Hotkey Test", 64

    Sleep 2000

    ; 方法1: SendPlay
    DebugLog("Sending via SendPlay...")
    SendPlay "^+!g"
    Sleep 200

    ; 方法2: SendEvent
    DebugLog("Sending via SendEvent...")
    SendEvent "^+!g"
    Sleep 200

    ; 方法3: SendInput
    DebugLog("Sending via SendInput...")
    SendInput "^+!g"
    Sleep 200

    ; 方法4: ControlSend
    if obsRunning {
        DebugLog("Sending via ControlSend to OBS...")
        ControlSend "^+!g", , "ahk_exe obs64.exe"
        Sleep 200
    }

    SoundBeep 1500, 100
    MsgBox "All methods tried!`n`nDid OBS receive any of them?`n`nIf not, try:`n1. Run this script as Administrator`n2. Check OBS hotkey settings`n3. Make sure OBS is not running as Admin", "Test Complete", 64
}

^!x::ExitApp