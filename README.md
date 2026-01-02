# LiveSplit Gold Alert

LiveSplitでゴールドスプリットを検出し、OBSに自動的にホットキーを送信するAutoHotkeyスクリプトです。

## 機能

- LiveSplitのゴールドスプリット（マイナスデルタ）を自動検出
- 検出時にOBSへホットキー（Ctrl+Shift+Alt+G）を送信
- 動画ソースを10秒間表示後、自動的に非表示
- 10秒以内に次のゴールドが出た場合、自動的にリセット・再表示
- デバッグログ機能

## 必要要件

- Windows 10/11
- [AutoHotkey v2.0](https://www.autohotkey.com/)
- [LiveSplit 1.8.36](https://livesplit.org/) 以降
- [OBS Studio](https://obsproject.com/)

## セットアップ

### 1. LiveSplit設定

1. LiveSplitを開く
2. 右クリック → `Control` → `Start TCP Server`
   - デフォルトでポート `16834` が使用されます
   - サーバーが起動すると、メニューに `Stop TCP Server` と表示されます

### 2. OBS設定

1. OBSを開く
2. `設定` → `ホットキー`
3. 表示したいソース/シーンに `Ctrl+Shift+Alt+G` を設定
   - 例: 特定のソースの表示/非表示トグル

### 3. スクリプト実行

1. `LiveSplitGoldAlert.ahk` をダブルクリック
2. 管理者権限での実行を許可
3. スクリプトがバックグラウンドで動作開始

## 使い方

スクリプトが起動していれば、LiveSplitでゴールドスプリットが出た時に自動的に：

1. OBSに `Ctrl+Shift+Alt+G` を送信（動画表示）
2. ビープ音が鳴る
3. 10秒後に自動的に同じホットキーを送信（動画非表示）

### 10秒以内に次のゴールド

- 現在の表示を一度非表示
- 再度表示
- 新しい10秒タイマー開始

## デバッグホットキー

| ホットキー | 機能 |
|-----------|------|
| `Ctrl+Alt+T` | 手動でゴールド検出テスト |
| `Ctrl+Alt+V` | TCP接続テスト |
| `Ctrl+Alt+H` | ホットキー送信テスト |
| `Ctrl+Alt+L` | デバッグログをメモ帳で開く |
| `Ctrl+Alt+C` | デバッグログをクリア |
| `Ctrl+Alt+D` | デバッグモードのON/OFF |
| `Ctrl+Alt+X` | スクリプト終了 |

## 設定変更

スクリプト上部で以下の設定を変更できます：

```ahk
LiveSplitHost := "127.0.0.1"      ; LiveSplitのホスト
LiveSplitPort := 16834             ; LiveSplitのポート
CheckInterval := 2000              ; チェック間隔（ミリ秒）
AutoHideDelay := 10000             ; 自動非表示までの時間（ミリ秒）
DebugMode := true                  ; デバッグモード
```

## トラブルシューティング

### ゴールドが検出されない

1. LiveSplit Serverが起動しているか確認（`Ctrl+Alt+V`でテスト）
2. ポート番号が `16834` になっているか確認
3. デバッグログを確認（`Ctrl+Alt+L`）

### OBSがホットキーを受け取らない

1. スクリプトが管理者権限で動作しているか確認
2. OBSが管理者権限で動作していないか確認
3. OBSのホットキー設定を確認
4. `Ctrl+Alt+H` でホットキー送信テスト

### 動画が自動的に消えない

- OBSのホットキーが「トグル」設定になっているか確認
- 2回同じホットキーを送ることで表示/非表示を切り替えます

## ライセンス

MIT License

## 作者

azumag
