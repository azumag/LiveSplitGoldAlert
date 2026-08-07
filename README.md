# LiveSplit Gold Alert

LiveSplitでゴールドスプリットを検出し、OBS WebSocket API経由でゴールド動画ソースの表示/非表示を自動制御するAutoHotkeyスクリプトです。

## 機能

- LiveSplitのゴールドスプリット（セグメントベスト）を自動検出
  - Best Segments比較を使用し、真のゴールド（区間ベストを超えた場合）のみを検出
  - グリーン（マイナスデルタ）との誤検出を防止
- 検出時にOBS WebSocket API経由でゴールド動画ソースを直接表示/非表示
- 10秒後、自動的に非表示（SetSceneItemEnabledで直接制御）
- 10秒以内に次のゴールドが出た場合、自動的にリセット・再表示
- デバッグログ機能

## 必要要件

- Windows 10/11
- [AutoHotkey v2.0](https://www.autohotkey.com/)
- [LiveSplit 1.8.36](https://livesplit.org/) 以降
- [OBS Studio](https://obsproject.com/)

## セットアップ

### 0. AutoHotKey を導入
- [AutoHotkey v2.0](https://www.autohotkey.com/)

### 1. LiveSplit設定

1. LiveSplitを開く
2. 右クリック → `Control` → `Start TCP Server`
   - デフォルトでポート `16834` が使用されます
   - サーバーが起動すると、メニューに `Stop TCP Server` と表示されます

### 2. OBS設定

1. OBSを開く
2. `ツール` → `obs-websocket設定` を開く
   - `WebSocketサーバーを有効にする` にチェック（ポートはデフォルトの `4455`）
   - パスワードを確認・メモする（デフォルトで自動生成されています）
3. スクリプト上部の設定にシーン名・ソース名を記入
   - `OBSPassword`: 手順2で確認したパスワード
   - `OBSSceneName`: ゴールド動画ソースが配置されているシーン名
   - `OBSSourceName`: 表示/非表示を切り替えるソース名

### 3. スクリプト実行

1. `LiveSplitGoldAlert.ahk` をダブルクリック
2. 管理者権限での実行を許可
3. スクリプトがバックグラウンドで動作開始

## 使い方

スクリプトが起動していれば、LiveSplitでゴールドスプリットが出た時に自動的に：

1. OBS WebSocket経由でソースを表示（動画表示）
2. ビープ音が鳴る
3. 10秒後に自動的に非表示

### 10秒以内に次のゴールド

- 現在の表示を一度非表示
- 再度表示
- 新しい10秒タイマー開始

## ホットキー

| ホットキー | 機能 |
|-----------|------|
| `Ctrl+Alt+B` | ビープ音のON/OFF切り替え |
| `Ctrl+Alt+X` | スクリプト終了 |

### デバッグモード時のみ有効なホットキー

スクリプト内の`DebugMode`を`true`に設定すると、以下のテスト用ホットキーが有効になります：

| ホットキー | 機能 |
|-----------|------|
| `Ctrl+Alt+T` | 手動でゴールド検出テスト |
| `Ctrl+Alt+V` | TCP接続テスト |
| `Ctrl+Alt+H` | OBS WebSocket接続・表示/非表示テスト |
| `Ctrl+Alt+L` | デバッグログをメモ帳で開く |
| `Ctrl+Alt+C` | デバッグログをクリア |

## 設定変更

スクリプト上部で以下の設定を変更できます：

```ahk
LiveSplitHost := "127.0.0.1"      ; LiveSplitのホスト
LiveSplitPort := 16834             ; LiveSplitのポート
OBSHost := "127.0.0.1"             ; OBS WebSocketのホスト
OBSPort := 4455                    ; OBS WebSocketのポート
OBSPassword := "password"          ; obs-websocket設定のパスワード
OBSSceneName := "Game"             ; 動画が置かれているシーン名
OBSSourceName := "GoldVideo"       ; ゴールド動画ソース名
CheckInterval := 2000              ; チェック間隔（ミリ秒）
AutoHideDelay := 10000             ; 自動非表示までの時間（ミリ秒）
PlayBeepSound := false             ; ビープ音を鳴らすか（デフォルト: OFF）
DebugMode := false                 ; デバッグモード（デフォルト: OFF）
```

**注:** ビープ音は実行中に `Ctrl+Alt+B` で切り替えることもできます

## 仕組み

スクリプトはLiveSplitの**Best Segments比較**を使用してゴールド検出を行います：

1. スプリット完了を検出（最終スプリット時間の変化）
2. 現在のセグメントタイムを計算（現在のスプリット時間 - 前回のスプリット時間）
3. Best Segmentsから該当セグメントのベストタイムを取得
4. 現在のセグメントタイム < ベストセグメントタイムの場合、ゴールドと判定

ゴールドを検出すると、**OBS WebSocket API**（ポート4455）でゴールド動画ソースを直接表示します：

1. WebSocket接続 → パスワード認証（SHA256チャレンジレスポンス）
2. `GetSceneItemId`でソースのIDを取得
3. `SetSceneItemEnabled`で表示/非表示を直接制御
4. 10秒後、自動的に非表示

これにより：
- **真のゴールドのみを検出**（PBより速いだけのグリーンは検出されない）
- **スクリプト再起動後も正確に動作**（LiveSplitに保存されたデータを使用）
- **ホットキー送信が不要**（権限差・フォーカス・ポーリング取りこぼしの問題を回避）

## トラブルシューティング

### ゴールドが検出されない

1. LiveSplit Serverが起動しているか確認
   - スクリプト内の`DebugMode := true`に変更して `Ctrl+Alt+V` でテスト可能
2. ポート番号が `16834` になっているか確認
3. LiveSplitにBest Segmentsデータが存在するか確認
   - 最低1回は完走している必要があります
4. デバッグログを確認
   - スクリプト内の`DebugMode := true`に変更して `Ctrl+Alt+L` でログを開く

### OBS側で動画が表示されない

1. OBS 28以上で実行しているか確認（それ以前はWebSocketプラグインの導入が必要）
2. `ツール` → `obs-websocket設定` でサーバーが有効になっているか確認
3. スクリプト内の`OBSPassword` / `OBSSceneName` / `OBSSourceName` が正しいか確認
4. WebSocket接続テスト
   - スクリプト内の`DebugMode := true`に変更して `Ctrl+Alt+H` でテスト可能

### 動画が自動的に消えない

- OBS WebSocket経由で直接非表示にするため、ホットキー設定は不要です
- 10秒後に自動的に同じソースを非表示にします

## ライセンス

MIT License

## 作者

azumag
