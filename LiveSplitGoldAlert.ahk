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

; OBS WebSocket接続設定（OBS 28以降に標準内蔵）
; 有効化: OBS → ツール → obs-websocket設定 → サーバーを有効化し、パスワードを確認する
OBSHost := "127.0.0.1"
OBSPort := 4455
OBSPassword := ""      ; obs-websocket設定で表示されるパスワード
OBSSceneName := ""     ; ゴールド動画ソースが配置されているシーン名
OBSSourceName := ""    ; 表示/非表示を切り替えるソース名

PreviousLastSplitTime := ""
BestSegmentSnapshots := Map() ; スプリット完了前に取得したBest Segments累積時間
LastSplitsSnapshotAttempt := 0
LoadedSplitsPath := ""
DebugMode := false  ; デバッグモード（デフォルト: OFF）
CheckInterval := 2000  ; チェック間隔（ミリ秒）- 2秒に1回
LastCheckTime := 0
AutoHideDelay := 10000  ; 自動非表示までの時間（ミリ秒）- 10秒
IsVideoVisible := false  ; 動画が表示されているか
PlayBeepSound := false  ; ビープ音を鳴らすか

; 設定ファイル（exeと同じフォルダの LiveSplitGoldAlert.ini）から設定を読み込む
; INIファイルが無い場合は上記のデフォルト値が使われる
ConfigFile := A_ScriptDir . "\LiveSplitGoldAlert.ini"
LoadConfig()
ValidateStartupConfig()

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

; 設定ファイルから設定を読み込む（INI形式・UTF-8対応）
; ファイルが無い場合はスクリプト上部のデフォルト値がそのまま使われる
LoadConfig() {
    global ConfigFile, LiveSplitHost, LiveSplitPort, OBSHost, OBSPort
    global OBSPassword, OBSSceneName, OBSSourceName
    global CheckInterval, AutoHideDelay, PlayBeepSound, DebugMode

    if !FileExist(ConfigFile) {
        return
    }

    try {
        content := FileRead(ConfigFile, "UTF-8")
    } catch {
        DebugLog("Config: could not read " . ConfigFile)
        return
    }

    section := ""
    for line in StrSplit(content, "`n", "`r") {
        line := Trim(line)
        ; 空行・コメント行はスキップ
        if (line == "" || SubStr(line, 1, 1) == ";" || SubStr(line, 1, 1) == "#") {
            continue
        }
        ; セクション行
        if (SubStr(line, 1, 1) == "[" && SubStr(line, -1) == "]") {
            section := Trim(SubStr(line, 2, -2))
            continue
        }
        ; キー=値
        eqPos := InStr(line, "=")
        if (eqPos == 0) {
            continue
        }
        key := Trim(SubStr(line, 1, eqPos - 1))
        value := Trim(SubStr(line, eqPos + 1))

        if (section == "OBS") {
            switch key, false {
                case "Host": OBSHost := value
                case "Port":
                    if IsInteger(value) {
                        OBSPort := Integer(value)
                    }
                case "Password": OBSPassword := value
                case "SceneName": OBSSceneName := value
                case "SourceName": OBSSourceName := value
            }
        } else if (section == "LiveSplit") {
            switch key, false {
                case "Host": LiveSplitHost := value
                case "Port":
                    if IsInteger(value) {
                        LiveSplitPort := Integer(value)
                    }
            }
        } else if (section == "General") {
            switch key, false {
                case "CheckInterval":
                    if IsInteger(value) {
                        CheckInterval := Integer(value)
                    }
                case "AutoHideDelay":
                    if IsInteger(value) {
                        AutoHideDelay := Integer(value)
                    }
                case "PlayBeepSound": PlayBeepSound := (StrLower(value) == "true" || value == "1")
                case "DebugMode": DebugMode := (StrLower(value) == "true" || value == "1")
            }
        }
    }

    DebugLog("Config loaded from " . ConfigFile)
}

; 複数のLiveSplitコマンドを同一TCPセッションで送信し、応答を配列で返す
SendLiveSplitCommands(commands) {
    global LiveSplitHost, LiveSplitPort

    results := []
    for index, command in commands {
        results.Push("")
    }

    ; セキュリティ: 入力検証
    ; ホストは127.0.0.1またはlocalhostのみ許可
    if (LiveSplitHost != "127.0.0.1" && LiveSplitHost != "localhost") {
        DebugLog("Security: Invalid host rejected: " . LiveSplitHost)
        return results
    }

    ; ポートは1-65535の数値のみ許可
    if (!IsInteger(LiveSplitPort) || LiveSplitPort < 1 || LiveSplitPort > 65535) {
        DebugLog("Security: Invalid port rejected: " . LiveSplitPort)
        return results
    }

    commandLines := ""
    for index, command in commands {
        escapedCommand := StrReplace(command, "'", "''")
        commandLines .= "    '" . escapedCommand . "',`n"
    }

    ; PowerShellスクリプトを一時ファイルに作成
    psScript := (
        "$ErrorActionPreference = 'Stop'`n"
        "try {`n"
        "    `$commands = @(`n"
        commandLines
        "    )`n"
        "    `$client = New-Object System.Net.Sockets.TcpClient`n"
        "    `$client.Connect('" . LiveSplitHost . "', " . LiveSplitPort . ")`n"
        "    `$stream = `$client.GetStream()`n"
        "    `$stream.ReadTimeout = 1500`n"
        "    `$stream.WriteTimeout = 1500`n"
        "    `$writer = New-Object System.IO.StreamWriter(`$stream)`n"
        "    `$reader = New-Object System.IO.StreamReader(`$stream)`n"
        "    `$writer.AutoFlush = `$true`n"
        "    for (`$i = 0; `$i -lt `$commands.Count; `$i++) {`n"
        "        `$response = ''`n"
        "        try {`n"
        "            `$writer.WriteLine(`$commands[`$i])`n"
        "            `$response = `$reader.ReadLine()`n"
        "        } catch {`n"
        "            `$response = ''`n"
        "            break`n"
        "        }`n"
        "        Write-Output ('R' + `$i + '=' + `$response)`n"
        "    }`n"
        "    `$client.Close()`n"
        "} catch {`n"
        "    for (`$i = 0; `$i -lt `$commands.Count; `$i++) {`n"
        "        Write-Output ('R' + `$i + '=')`n"
        "    }`n"
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

            for line in StrSplit(output, "`n", "`r") {
                line := Trim(line)
                eqPos := InStr(line, "=")
                if (SubStr(line, 1, 1) != "R" || eqPos == 0) {
                    continue
                }

                responseIndex := SubStr(line, 2, eqPos - 2)
                if (!IsInteger(responseIndex)) {
                    continue
                }

                responseIndex := Integer(responseIndex)
                if (responseIndex >= 1 && responseIndex <= results.Length) {
                    results[responseIndex] := SubStr(line, eqPos + 1)
                }
            }

            return results
        }

        DebugLog("LiveSplit command batch: no output")
        return results
    } catch as err {
        DebugLog("Command error: " . err.Message)
        return results
    }
}

; LiveSplitにTCPソケット経由で単一コマンドを送信（テスト用ラッパー）
SendLiveSplitCommand(command) {
    results := SendLiveSplitCommands([command])
    return results.Length > 0 ? results[1] : ""
}

; OBS WebSocket経由でソースの表示/非表示を直接制御（PowerShell経由）
; 戻り値: 成功ならtrue、失敗ならfalse
SendOBSCommand(enabled) {
    global OBSHost, OBSPort, OBSPassword, OBSSceneName, OBSSourceName

    DebugLog("OBS WebSocket: setting [" . OBSSourceName . "] enabled=" . (enabled ? "true" : "false"))

    ; セキュリティ: 入力検証（ホストは127.0.0.1またはlocalhostのみ許可）
    if (OBSHost != "127.0.0.1" && OBSHost != "localhost") {
        DebugLog("Security: Invalid OBS host rejected: " . OBSHost)
        return false
    }

    ; ポートは1-65535の数値のみ許可
    if (!IsInteger(OBSPort) || OBSPort < 1 || OBSPort > 65535) {
        DebugLog("Security: Invalid OBS port rejected: " . OBSPort)
        return false
    }

    ; シーン名・ソース名が未設定の場合はホットキーにフォールバック
    if (OBSSceneName == "" || OBSSourceName == "") {
        DebugLog("OBS WebSocket: scene/source name not configured - falling back to hotkey")
        SendGoldHotkey()
        return false
    }

    ; 値は環境変数経由で渡す（引用符エスケープ問題を回避）
    EnvSet "OBS_WS_HOST", OBSHost
    EnvSet "OBS_WS_PORT", OBSPort
    EnvSet "OBS_WS_PASSWORD", OBSPassword
    EnvSet "OBS_WS_SCENE", OBSSceneName
    EnvSet "OBS_WS_SOURCE", OBSSourceName
    EnvSet "OBS_WS_ENABLED", enabled ? "true" : "false"

    psScript := "
(
$ErrorActionPreference = 'Stop'
try {
    $host_ = $env:OBS_WS_HOST
    $port = $env:OBS_WS_PORT
    $password = $env:OBS_WS_PASSWORD
    $scene = $env:OBS_WS_SCENE
    $source = $env:OBS_WS_SOURCE
    $enabled = ($env:OBS_WS_ENABLED -eq 'true')
    $ws = New-Object System.Net.WebSockets.ClientWebSocket
    $uri = [Uri]('ws://' + $host_ + ':' + $port)
    $recvBuf = New-Object byte[] 65536
    function Await-Task($task, $timeoutMs, $timeoutMsg) {
        try {
            if (-not $task.Wait($timeoutMs)) { throw $timeoutMsg }
            return $task.GetAwaiter().GetResult()
        } catch [System.AggregateException] {
            throw $_.Exception.InnerException
        }
    }
    function Receive-Json {
        $sb = New-Object System.Text.StringBuilder
        do {
            $r = Await-Task $ws.ReceiveAsync([ArraySegment[byte]]::new($recvBuf), [Threading.CancellationToken]::None) 5000 'Timeout waiting for response from OBS'
            if ($r.MessageType -eq [Net.WebSockets.WebSocketMessageType]::Close) { throw 'Connection closed by server' }
            [void]$sb.Append([Text.Encoding]::UTF8.GetString($recvBuf, 0, $r.Count))
        } while (-not $r.EndOfMessage)
        return ($sb.ToString() | ConvertFrom-Json)
    }
    function Send-Json($obj) {
        $json = $obj | ConvertTo-Json -Compress -Depth 10
        $bytes = [Text.Encoding]::UTF8.GetBytes($json)
        [void](Await-Task $ws.SendAsync([ArraySegment[byte]]::new($bytes), [Net.WebSockets.WebSocketMessageType]::Text, $true, [Threading.CancellationToken]::None) 5000 'Timeout sending to OBS')
    }
    [void](Await-Task $ws.ConnectAsync($uri, [Threading.CancellationToken]::None) 5000 'Timeout connecting to OBS')
    $hello = Receive-Json
    if ($hello.op -ne 0) { throw 'Unexpected message, expected Hello (op 0)' }
    $identify = @{ op = 1; d = @{ rpcVersion = 1; eventSubscriptions = 0 } }
    if ($hello.d.authentication) {
        $sha = [Security.Cryptography.SHA256]::Create()
        $secret = [Convert]::ToBase64String($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($password + $hello.d.authentication.salt)))
        $auth = [Convert]::ToBase64String($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($secret + $hello.d.authentication.challenge)))
        $identify.d.authentication = $auth
    }
    Send-Json $identify
    $identified = Receive-Json
    if ($identified.op -ne 2) { throw 'Identification failed (op ' + $identified.op + ')' }
    $reqGet = @{ op = 6; d = @{ requestType = 'GetSceneItemId'; requestId = 'gold1'; requestData = @{ sceneName = $scene; sourceName = $source } } }
    Send-Json $reqGet
    $resGet = Receive-Json
    if (-not $resGet.d.requestStatus.result) { throw 'GetSceneItemId failed: code ' + $resGet.d.requestStatus.code }
    $sceneItemId = $resGet.d.responseData.sceneItemId
    $reqSet = @{ op = 6; d = @{ requestType = 'SetSceneItemEnabled'; requestId = 'gold2'; requestData = @{ sceneName = $scene; sceneItemId = $sceneItemId; sceneItemEnabled = $enabled } } }
    Send-Json $reqSet
    $resSet = Receive-Json
    if (-not $resSet.d.requestStatus.result) { throw 'SetSceneItemEnabled failed: code ' + $resSet.d.requestStatus.code }
    $ws.Dispose()
    Write-Output 'OK'
} catch {
    Write-Output ('ERR: ' + $_.Exception.Message)
}
)"

    ; UTF-8 BOM付きで保存（PowerShell 5.1はBOMなしUTF-8をANSIと解釈するため）
    tempFile := A_Temp . "\obs_ws.ps1"
    try {
        file := FileOpen(tempFile, "w", "UTF-8")
        file.Write(psScript)
        file.Close()

        outputFile := A_Temp . "\obs_ws_output.txt"
        cmdLine := "powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -NoProfile -Command `"& '" . tempFile . "' | Out-File -Encoding UTF8 '" . outputFile . "'`""
        shell := ComObject("WScript.Shell")
        shell.Run(cmdLine, 0, true)

        if FileExist(outputFile) {
            outputFileObj := FileOpen(outputFile, "r")
            output := outputFileObj.Read()
            outputFileObj.Close()
            FileDelete(outputFile)

            result := (Trim(output, "`r`n `t") == "OK")
            if (result) {
                DebugLog("OBS WebSocket: OK")
            } else {
                DebugLog("OBS WebSocket failed: " . Trim(output, "`r`n `t"))
            }
            return result
        }

        DebugLog("OBS WebSocket: no response")
        return false
    } catch as err {
        DebugLog("OBS WebSocket error: " . err.Message)
        return false
    }
}

; スプリット完了前にBest Segments累積時間を保存する
StoreBestSnapshot(splitIndex, bestSegmentTime) {
    global BestSegmentSnapshots

    if (!IsInteger(splitIndex) || Integer(splitIndex) < 0 || bestSegmentTime == "" || bestSegmentTime == "-") {
        return
    }

    BestSegmentSnapshots[Integer(splitIndex)] := bestSegmentTime
}

; 保存済みBest Segments累積値から完了セグメントのベストタイムを作る
GetBestSegmentSeconds(completedIndex) {
    global BestSegmentSnapshots

    if (completedIndex < 0) {
        return ""
    }

    if (completedIndex == 0) {
        return BestSegmentSnapshots.Has(0) ? ParseTimeToSeconds(BestSegmentSnapshots[0]) : ""
    }

    if (!BestSegmentSnapshots.Has(completedIndex) || !BestSegmentSnapshots.Has(completedIndex - 1)) {
        return ""
    }

    return ParseTimeToSeconds(BestSegmentSnapshots[completedIndex]) - ParseTimeToSeconds(BestSegmentSnapshots[completedIndex - 1])
}

; 途中起動や取りこぼしに備えて、splitsファイルからBest Segment時間を復元する
LoadBestSegmentsFromSplitsFile() {
    global BestSegmentSnapshots, LastSplitsSnapshotAttempt, LoadedSplitsPath

    now := A_TickCount
    if (LastSplitsSnapshotAttempt != 0 && now - LastSplitsSnapshotAttempt < 10000) {
        return
    }
    LastSplitsSnapshotAttempt := now

    splitsPath := SendLiveSplitCommand("getsplitspath")
    if (splitsPath == "" || splitsPath == "-" || !FileExist(splitsPath)) {
        DebugLog("Splits file snapshot unavailable: [" . splitsPath . "]")
        return
    }

    EnvSet "LIVESPLIT_SPLITS_PATH", splitsPath
    psScript := "
(
$ErrorActionPreference = 'Stop'
try {
    [xml]$xml = Get-Content -LiteralPath $env:LIVESPLIT_SPLITS_PATH -Raw
    $segments = @($xml.Run.Segments.Segment)
    for ($i = 0; $i -lt $segments.Count; $i++) {
        $best = $segments[$i].BestSegmentTime
        if ($null -eq $best) { continue }
        $realTime = $best.SelectSingleNode('./RealTime')
        $gameTime = $best.SelectSingleNode('./GameTime')
        $duration = ''
        if ($realTime -and -not [string]::IsNullOrWhiteSpace($realTime.InnerText)) {
            $duration = $realTime.InnerText
        } elseif ($gameTime -and -not [string]::IsNullOrWhiteSpace($gameTime.InnerText)) {
            $duration = $gameTime.InnerText
        }
        if ([string]::IsNullOrWhiteSpace($duration)) { continue }
        $seconds = [System.Xml.XmlConvert]::ToTimeSpan($duration).TotalSeconds
        Write-Output ('B' + $i + '=' + $seconds)
    }
} catch {
    Write-Output ('ERR: ' + $_.Exception.Message)
}
)"

    tempFile := A_Temp . "\livesplit_best_segments.ps1"
    try {
        file := FileOpen(tempFile, "w", "UTF-8")
        file.Write(psScript)
        file.Close()

        outputFile := A_Temp . "\livesplit_best_segments_output.txt"
        cmdLine := "powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -NoProfile -Command `"& '" . tempFile . "' | Out-File -Encoding UTF8 '" . outputFile . "'`""
        shell := ComObject("WScript.Shell")
        shell.Run(cmdLine, 0, true)

        if !FileExist(outputFile) {
            DebugLog("Splits file snapshot: no output")
            return
        }

        outputFileObj := FileOpen(outputFile, "r")
        output := outputFileObj.Read()
        outputFileObj.Close()
        FileDelete(outputFile)

        fileSnapshots := Map()
        hasParseError := InStr(output, "ERR: ") > 0
        for line in StrSplit(output, "`n", "`r") {
            line := Trim(line)
            eqPos := InStr(line, "=")
            if (SubStr(line, 1, 1) != "B" || eqPos == 0) {
                continue
            }

            segmentIndex := SubStr(line, 2, eqPos - 2)
            segmentTime := SubStr(line, eqPos + 1)
            if (!IsInteger(segmentIndex)) {
                continue
            }

            if (!hasParseError && segmentTime != "" && segmentTime != "-") {
                fileSnapshots[Integer(segmentIndex)] := segmentTime
            }
        }

        ; パース成功時だけ入れ替える。失敗時に現在の監視スナップショットを失わない。
        if (!hasParseError) {
            if (splitsPath != LoadedSplitsPath) {
                ; splitsファイルが変わった場合は、前のゲーム用スナップショットを使わない
                BestSegmentSnapshots.Clear()
                LoadedSplitsPath := splitsPath
            }

            for segmentIndex, segmentTime in fileSnapshots {
                BestSegmentSnapshots[segmentIndex] := segmentTime
            }
        }

        DebugLog("Splits file snapshot loaded: " . fileSnapshots.Count . " entries"
            . ", parse error=" . (hasParseError ? "yes" : "no")
            . ", total " . BestSegmentSnapshots.Count)
    } catch as err {
        DebugLog("Splits file snapshot error: " . err.Message)
    }
}

; 起動時に必須設定を可視化する（フォールバックは残すが、黙失敗を避ける）
ValidateStartupConfig() {
    global OBSSceneName, OBSSourceName, LiveSplitHost, LiveSplitPort, OBSHost, OBSPort

    DebugLog("Config effective - LiveSplit=" . LiveSplitHost . ":" . LiveSplitPort
        . ", OBS=" . OBSHost . ":" . OBSPort
        . ", Scene=[" . OBSSceneName . "]"
        . ", Source=[" . OBSSourceName . "]")

    if (OBSSceneName == "" || OBSSourceName == "") {
        TrayTip "LiveSplit Gold Alert", "OBS SceneName / SourceName 未設定です。LiveSplitGoldAlert.ini を確認してください。", 2
    }
}

CheckGold() {
    global PreviousLastSplitTime, LastCheckTime, BestSegmentSnapshots

    ; レート制限: 最後のチェックから500ms以内は何もしない
    currentTime := A_TickCount
    if (currentTime - LastCheckTime < 500) {
        return
    }
    LastCheckTime := currentTime

    try {
        ; インデックスとBest Segmentsを先に取得してからlast timeを見る。
        ; 同一TCPセッションで取得することで、スプリット直前の比較値を保存しやすくする。
        responses := SendLiveSplitCommands([
            "getsplitindex",
            "getcomparisonsplittime Best Segments",
            "getlastsplittime"
        ])

        splitIndex := responses[1]
        bestSegmentTime := responses[2]
        lastSplitTime := responses[3]

        if (lastSplitTime == "") {
            return
        }

        StoreBestSnapshot(splitIndex, bestSegmentTime)
        if (IsInteger(splitIndex) && BestSegmentSnapshots.Count < (Integer(splitIndex) + 1)) {
            LoadBestSegmentsFromSplitsFile()
        }

        ; 初回起動時・リセット後: 次の最初のスプリットに備えて状態を揃える
        if (PreviousLastSplitTime == "" || lastSplitTime == "-") {
            PreviousLastSplitTime := lastSplitTime
            DebugLog("Initial/Reset state - Index: [" . splitIndex . "]"
                . ", Last: [" . lastSplitTime . "]"
                . ", Best Segment: [" . bestSegmentTime . "]")
            return
        }

        ; 最終スプリット時間が変わった場合（新しいスプリット完了）
        if (lastSplitTime == PreviousLastSplitTime) {
            return
        }

        ; スプリット取り消しなどで時間が逆戻りした場合は再初期化
        if (ParseTimeToSeconds(lastSplitTime) < ParseTimeToSeconds(PreviousLastSplitTime)) {
            DebugLog("=== UNDO SPLIT DETECTED (time regression) - re-initializing ===")
            PreviousLastSplitTime := lastSplitTime
            return
        }

        DebugLog("=== NEW SPLIT DETECTED ===")
        DebugLog("Split Index: [" . splitIndex . "]")
        DebugLog("Previous Last Split:  [" . PreviousLastSplitTime . "]")
        DebugLog("Current Last Split:   [" . lastSplitTime . "]")

        ; splitIndexが読めない場合は完了インデックスも確定しないためスキップする
        justCompletedIndex := -1
        if (IsInteger(splitIndex)) {
            justCompletedIndex := Integer(splitIndex) - 1
        }

        currentSegmentSeconds := ""
        if (justCompletedIndex == 0) {
            currentSegmentSeconds := ParseTimeToSeconds(lastSplitTime)
        } else if (justCompletedIndex > 0 && PreviousLastSplitTime != "-" && PreviousLastSplitTime != "") {
            currentSegmentSeconds := ParseTimeToSeconds(lastSplitTime) - ParseTimeToSeconds(PreviousLastSplitTime)
        }

        bestSegmentSeconds := GetBestSegmentSeconds(justCompletedIndex)
        hasComparableSegment := (currentSegmentSeconds != "" && bestSegmentSeconds != "")

        if (!hasComparableSegment) {
            DebugLog("No valid pre-split Best Segment snapshot - completed index: " . justCompletedIndex)
        } else {
            DebugLog("Current Segment Time: " . Round(currentSegmentSeconds, 3) . " seconds")
            DebugLog("Best Segment Time:    " . Round(bestSegmentSeconds, 3) . " seconds")

            ; ゴールド判定: 現在のセグメントタイム < ベストセグメントタイム
            isGold := (currentSegmentSeconds < bestSegmentSeconds)
            DebugLog("Gold check: " . (isGold ? "YES - New segment best!" : "NO - Not a gold"))

            if (isGold) {
                DebugLog(">>> GOLD SPLIT DETECTED! <<<")

                ; 再確認
                confirmResponses := SendLiveSplitCommands(["getlastsplittime"])
                if (confirmResponses[1] == lastSplitTime) {
                    DebugLog("*** CONFIRMED GOLD - Triggering alert! ***")
                    improvement := bestSegmentSeconds - currentSegmentSeconds
                    DebugLog("Improvement: " . Round(improvement, 3) . " seconds")
                    TriggerGoldAlert("Segment: " . Round(currentSegmentSeconds, 2) . "s (Best: " . Round(bestSegmentSeconds, 2) . "s)")
                } else {
                    DebugLog("Split time changed during re-check - skipping")
                }
            }
        }

        PreviousLastSplitTime := lastSplitTime
    } catch as err {
        DebugLog("CheckGold error: " . err.Message)
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
    DebugLog("!!! GOLD SPLIT DETECTED !!! Showing video in OBS...")
    DebugLog("Delta: [" . delta . "]")

    global AutoHideDelay, IsVideoVisible, PlayBeepSound

    ; 既存の自動非表示タイマーをキャンセル
    SetTimer AutoHideGold, 0

    ; 既に動画が表示されている場合は、一度非表示にしてから再表示
    if (IsVideoVisible) {
        DebugLog("Video already visible - hiding first, then showing again")
        SendOBSCommand(false)  ; 1回目: 非表示
        Sleep 200  ; 少し待つ
    }

    ; 表示（WebSocketが失敗した場合はホットキーにフォールバック）
    if (!SendOBSCommand(true)) {
        DebugLog("OBS WebSocket show failed - falling back to hotkey")
        SendGoldHotkey()
    }

    ; 動画が表示されている状態にする
    IsVideoVisible := true

    ; 10秒後に自動的に非表示にする
    SetTimer AutoHideGold, -AutoHideDelay

    TrayTip "Gold Split!", "Video will auto-hide in " . (AutoHideDelay // 1000) . " seconds`nDelta: " . delta, 1

    ; 音も鳴らす（設定で有効な場合のみ）
    if (PlayBeepSound) {
        SoundBeep 1000, 200
    }
}

; ホットキーを送信する関数（OBS WebSocketが使えない場合のフォールバック）
SendGoldHotkey() {
    DebugLog("Sending gold hotkey to OBS... (fallback)")

    ; トグル用ホットキーは1回だけ送信する
    ; 複数回送信すると表示状態が反転してしまい、動画が表示されない
    ; OBSのホットキーはGetAsyncKeyStateを約25ms間隔でポーリングして検出するため、
    ; SendInputの瞬時down/upでは押下状態を取りこぼす。
    ; SendEventで各キーを50ms押しっぱなしにして確実に検出させる
    SetKeyDelay 10, 50
    SendEvent "^+!g"
    DebugLog("Hotkey sent via SendEvent")
}

; 自動非表示タイマー
AutoHideGold() {
    global IsVideoVisible

    DebugLog("Auto-hiding gold video after 10 seconds...")
    SendOBSCommand(false)
    IsVideoVisible := false  ; 動画を非表示にした
    DebugLog("Auto-hide complete")
}

; TCPソケット接続テスト
TestTCPConnection() {
    global LiveSplitHost, LiveSplitPort

    commands := ["getsplitindex", "getdelta", "getlastsplittime", "getcurrenttime", "getfinaltime"]
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

        splitIndex := SendLiveSplitCommand("getsplitindex")
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

; OBS WebSocket接続テスト（デバッグモード時のみ）
^!h:: {
    global DebugMode, OBSSceneName, OBSSourceName
    if (!DebugMode) {
        return
    }

    if (OBSSceneName == "" || OBSSourceName == "") {
        MsgBox "OBSSceneName / OBSSourceName が未設定です。`nLiveSplitGoldAlert.ini で設定してください。", "OBS WebSocket Test", 48
        return
    }

    DebugLog("Testing OBS WebSocket (show)...")

    showOk := SendOBSCommand(true)
    Sleep 2000
    DebugLog("Testing OBS WebSocket (hide)...")
    hideOk := SendOBSCommand(false)

    msg := (
        "OBS WebSocket test result:`n"
        "- Show: " . (showOk ? "OK" : "FAILED") . "`n"
        "- Hide: " . (hideOk ? "OK" : "FAILED") . "`n`n"
        "If FAILED, check:`n"
        "1. OBS ツール → obs-websocket設定 でサーバーが有効か`n"
        "2. LiveSplitGoldAlert.ini の Password / SceneName / SourceName の設定`n"
        "3. デバッグログ (Ctrl+Alt+L) で詳細を確認"
    )

    MsgBox msg, "OBS WebSocket Test", 64
}

^!x::ExitApp
