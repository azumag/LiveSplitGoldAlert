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
PreviousLastSplitTime := ""
PreviousComparisonTime := ""
DebugMode := false  ; デバッグモード（デフォルト: OFF）
CheckInterval := 2000  ; チェック間隔（ミリ秒）- 2秒に1回
LastCheckTime := 0
AutoHideDelay := 10000  ; 自動非表示までの時間（ミリ秒）- 10秒
IsVideoVisible := false  ; 動画が表示されているか
PlayBeepSound := false  ; ビープ音を鳴らすか

; 定期的にチェック
SetTimer CheckGold, CheckInterval

; デバッグログ
DebugLog(msg) {
    global DebugMode
    if (DebugMode) {
        OutputDebug msg

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

    ; セキュリティ: 入力検証
    ; ホストは127.0.0.1またはlocalhostのみ許可
    if (LiveSplitHost != "127.0.0.1" && LiveSplitHost != "localhost") {
        DebugLog("Security: Invalid host rejected: " . LiveSplitHost)
        return ""
    }

    ; ポートは1-65535の数値のみ許可
    if (!IsInteger(LiveSplitPort) || LiveSplitPort < 1 || LiveSplitPort > 65535) {
        DebugLog("Security: Invalid port rejected: " . LiveSplitPort)
        return ""
    }

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
    global PreviousLastSplitTime, PreviousComparisonTime, LastCheckTime

    ; レート制限: 最後のチェックから500ms以内は何もしない
    currentTime := A_TickCount
    if (currentTime - LastCheckTime < 500) {
        return
    }
    LastCheckTime := currentTime

    try {
        ; スプリット完了を検出するため、最終スプリット時間（累積）を取得
        lastSplitTime := SendLiveSplitCommand("getlastsplittime")

        ; 初回起動時またはリセット後: 前回の時間を初期化するだけで終了
        if (PreviousLastSplitTime == "" || lastSplitTime == "-") {
            PreviousLastSplitTime := lastSplitTime
            ; Best Segments比較から前回のベストセグメント累積時間を取得
            bestSegmentTime := SendLiveSplitCommand("getcomparisonsplittime Best Segments")
            PreviousComparisonTime := bestSegmentTime
            DebugLog("Initial/Reset state - Last: [" . lastSplitTime . "], Best Segment: [" . bestSegmentTime . "]")
            return
        }

        ; 最終スプリット時間が変わった場合（新しいスプリット完了）
        if (lastSplitTime != "" && lastSplitTime != PreviousLastSplitTime) {
            DebugLog("=== NEW SPLIT DETECTED ===")

            ; 少し待ってからBest Segments比較時間を取得
            Sleep 200
            bestSegmentTime := SendLiveSplitCommand("getcomparisonsplittime Best Segments")

            ; 現在のスプリットインデックスも取得してデバッグ
            splitIndex := SendLiveSplitCommand("getcurrentsplitindex")
            delta := SendLiveSplitCommand("getdelta")

            DebugLog("Split Index: [" . splitIndex . "], Delta: [" . delta . "]")
            DebugLog("Previous Last Split:  [" . PreviousLastSplitTime . "]")
            DebugLog("Current Last Split:   [" . lastSplitTime . "]")
            DebugLog("Previous Best Segment: [" . PreviousComparisonTime . "]")
            DebugLog("Current Best Segment:  [" . bestSegmentTime . "]")

            ; セグメントタイムを計算
            ; 現在のセグメント = lastSplitTime - PreviousLastSplitTime
            ; ベストセグメント = PreviousComparisonTime - PreviousLastSplitTime
            ; ※Best Segments比較を使用することで、真のセグメントベストと比較できる

            if (lastSplitTime != "" && lastSplitTime != "-") {

                ; 現在のセグメントタイム
                if (PreviousLastSplitTime != "" && PreviousLastSplitTime != "-") {
                    currentSegmentSeconds := ParseTimeToSeconds(lastSplitTime) - ParseTimeToSeconds(PreviousLastSplitTime)
                } else {
                    ; 最初のスプリット
                    currentSegmentSeconds := ParseTimeToSeconds(lastSplitTime)
                }

                ; ベストセグメントタイム
                ; PreviousComparisonTimeを使用（スプリット完了前のBest Segments累積値）
                ; これにより、ゴールド取得後に更新されたBest Segmentsではなく、更新前の値で比較できる
                if (PreviousComparisonTime != "" && PreviousComparisonTime != "-") {
                    if (PreviousLastSplitTime != "" && PreviousLastSplitTime != "-") {
                        ; 中間スプリット: ベストセグメント = PreviousComparisonTime - PreviousLastSplitTime
                        bestSegmentSeconds := ParseTimeToSeconds(PreviousComparisonTime) - ParseTimeToSeconds(PreviousLastSplitTime)
                    } else {
                        ; 最初のスプリット: PreviousComparisonTimeがそのままベスト
                        bestSegmentSeconds := ParseTimeToSeconds(PreviousComparisonTime)
                    }

                    DebugLog("Current Segment Time: " . Round(currentSegmentSeconds, 3) . " seconds")
                    DebugLog("Best Segment Time:    " . Round(bestSegmentSeconds, 3) . " seconds")

                    ; ゴールド判定: 現在のセグメントタイム < ベストセグメントタイム
                    isGold := (currentSegmentSeconds < bestSegmentSeconds)
                } else {
                    ; Best Segmentデータなし
                    DebugLog("No Best Segment data available - skipping gold check")
                    isGold := false
                }

                DebugLog("Gold check: " . (isGold ? "YES - New segment best!" : "NO - Not a gold"))

                if (isGold) {
                    DebugLog(">>> GOLD SPLIT DETECTED! <<<")

                    ; 再確認
                    Sleep 100
                    lastSplitTime2 := SendLiveSplitCommand("getlastsplittime")

                    if (lastSplitTime2 == lastSplitTime) {
                        DebugLog("*** CONFIRMED GOLD - Triggering alert! ***")
                        improvement := bestSegmentSeconds - currentSegmentSeconds
                        DebugLog("Improvement: " . Round(improvement, 3) . " seconds")
                        TriggerGoldAlert("Segment: " . Round(currentSegmentSeconds, 2) . "s (Best: " . Round(bestSegmentSeconds, 2) . "s)")
                    } else {
                        DebugLog("Split time changed during re-check - skipping")
                    }
                }
            }

            ; 次のチェックのために現在の値を保存
            PreviousLastSplitTime := lastSplitTime
            PreviousComparisonTime := bestSegmentTime
        }
    } catch as err {
        ; エラーは無視（接続できない場合など）
    }
}

; 時刻文字列を比較（HH:MM:SS.mmm形式）
; 戻り値: -1 (time1 < time2), 0 (equal), 1 (time1 > time2)
CompareTime(time1, time2) {
    ; マイナス符号を処理
    sign1 := 1
    sign2 := 1

    if (SubStr(time1, 1, 1) == "-") {
        sign1 := -1
        time1 := SubStr(time1, 2)
    }

    if (SubStr(time2, 1, 1) == "-") {
        sign2 := -1
        time2 := SubStr(time2, 2)
    }

    ; 時刻を秒数に変換
    seconds1 := ParseTimeToSeconds(time1) * sign1
    seconds2 := ParseTimeToSeconds(time2) * sign2

    if (seconds1 < seconds2) {
        return -1
    } else if (seconds1 > seconds2) {
        return 1
    } else {
        return 0
    }
}

; 時刻文字列を秒数に変換
ParseTimeToSeconds(timeStr) {
    ; HH:MM:SS.mmm または MM:SS.mmm または SS.mmm
    parts := StrSplit(timeStr, ":")

    if (parts.Length == 3) {
        ; HH:MM:SS.mmm
        hours := parts[1]
        minutes := parts[2]
        seconds := parts[3]
        return (hours * 3600) + (minutes * 60) + seconds
    } else if (parts.Length == 2) {
        ; MM:SS.mmm
        minutes := parts[1]
        seconds := parts[2]
        return (minutes * 60) + seconds
    } else if (parts.Length == 1) {
        ; SS.mmm
        return parts[1]
    }

    return 0
}

; ゴールドアラートをトリガー
TriggerGoldAlert(delta) {
    DebugLog("!!! GOLD SPLIT DETECTED !!! Sending hotkey to OBS...")
    DebugLog("Delta: [" . delta . "]")

    global AutoHideDelay, IsVideoVisible, PlayBeepSound

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

    TrayTip "Gold Split!", "Video will auto-hide in 10 seconds`nDelta: " . delta, 1

    ; 音も鳴らす（設定で有効な場合のみ）
    if (PlayBeepSound) {
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

; 接続テスト（デバッグモード時のみ）
^!v:: {
    global DebugMode
    if (DebugMode) {
        TestTCPConnection()
    }
}

; 手動でゴールド検出テスト（デバッグモード時のみ）
^!t:: {
    global DebugMode
    if (!DebugMode) {
        return
    }
    try {
        DebugLog("=== Manual test - getting current state ===")

        splitIndex := SendLiveSplitCommand("getcurrentsplitindex")
        delta := SendLiveSplitCommand("getdelta")
        lastSplit := SendLiveSplitCommand("getlastsplittime")
        comparison := SendLiveSplitCommand("getcomparisonsplittime")
        bestSegment := SendLiveSplitCommand("getcomparisonsplittime Best Segments")

        info := (
            "Split Index: [" . splitIndex . "]`n"
            "Delta: [" . delta . "]`n"
            "Last Split Time: [" . lastSplit . "]`n"
            "Comparison Time (PB): [" . comparison . "]`n"
            "Best Segment Time: [" . bestSegment . "]`n`n"
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
            TriggerGoldAlert(delta)
        } else {
            MsgBox "No data received from LiveSplit Server.`n`nMake sure:`n1. LiveSplit is running`n2. TCP Server is started (Right-click -> Control -> Start TCP Server)`n3. Port is set to 16834", "Connection Failed", 48
        }
    } catch as err {
        DebugLog("Test error: " . err.Message)
        MsgBox "Error: " . err.Message, "Test Error", 16
    }
}

; ビープ音の切り替え
^!b:: {
    global PlayBeepSound
    PlayBeepSound := !PlayBeepSound
    msg := "Beep sound: " . (PlayBeepSound ? "ON" : "OFF")
    DebugLog(msg)
    MsgBox msg, "Beep Sound Toggle", 64
}

; ログファイルを開く（デバッグモード時のみ）
^!l:: {
    global DebugMode
    if (!DebugMode) {
        return
    }
    logFile := A_ScriptDir . "\debug.log"
    if FileExist(logFile) {
        Run "notepad.exe `"" . logFile . "`""
    } else {
        MsgBox "Log file not found: " . logFile, "No Log", 48
    }
}

; ログファイルをクリア（デバッグモード時のみ）
^!c:: {
    global DebugMode
    if (!DebugMode) {
        return
    }
    logFile := A_ScriptDir . "\debug.log"
    try {
        FileDelete logFile
        MsgBox "Log file cleared!", "Success", 64
    } catch {
        MsgBox "Could not clear log file", "Error", 16
    }
}

; ホットキー送信テスト（デバッグモード時のみ）
^!h:: {
    global DebugMode
    if (!DebugMode) {
        return
    }
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